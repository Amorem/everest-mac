import Foundation
import IOKit
import IOKit.hid

enum TransportError: Error, CustomStringConvertible {
    case notFound
    case openFailed(IOReturn)
    case io(IOReturn, String)

    var description: String {
        switch self {
        case .notFound: return "Mountain Everest keyboard not found (VID:PID 3282:0001)"
        case .openFailed(let r): return String(format: "could not open HID device (0x%08x)", r)
        case .io(let r, let what): return String(format: "%@ failed (0x%08x)", what, r)
        }
    }
}

/// IOKit HID transport for the Everest Max vendor interface (usage page 0xFF00).
///
/// The vendor interface (USB interface 3) carries 64-byte packets on an
/// interrupt endpoint pair. The first byte of each packet is the HID report
/// ID: 0x11 for commands, 0x12..0x17 for flash/RGB/dial operations, 0x01 for
/// button events coming back. IOKit wants the report ID separately from the
/// payload, so `write` splits the packet and the input callback rebuilds it.
final class Transport {
    static let vendorID = 0x3282
    static let productID = 0x0001
    static let vendorUsagePage = 0xFF00
    static let vendorUsage = 0x0001
    static let packetSize = 64

    private var manager: IOHIDManager?
    private(set) var device: IOHIDDevice?
    private var inbox: [[UInt8]] = []
    private let lock = NSLock()
    private var reportBuffer: UnsafeMutablePointer<UInt8>
    /// The run loop the input callback was scheduled on (the opening thread).
    private var runLoop: CFRunLoop?

    /// `productID` selects the device: the keyboard (0x0001) or the
    /// DisplayPad (`PadProto.productID`), which uses the same 64-byte vendor
    /// collection for its commands.
    init(productID: Int = Transport.productID, usagePage: Int = Transport.vendorUsagePage,
         usage: Int = Transport.vendorUsage) throws {
        reportBuffer = .allocate(capacity: 1024)
        reportBuffer.initialize(repeating: 0, count: 1024)

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager else { throw TransportError.notFound }

        let matches: [[String: Any]] = [[
            kIOHIDVendorIDKey as String: Transport.vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDPrimaryUsagePageKey as String: usagePage,
            kIOHIDPrimaryUsageKey as String: usage,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let res = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard res == kIOReturnSuccess else { throw TransportError.openFailed(res) }

        guard let set = IOHIDManagerCopyDevices(manager), CFSetGetCount(set) > 0 else {
            throw TransportError.notFound   // deinit closes the manager
        }
        // A keyboard exposes several HID interfaces with the same usage page
        // and usage (boot keyboard + the real one); the real one is the
        // interface with the larger input reports.
        let devices = (set as! Set<IOHIDDevice>).sorted { a, b in
            Transport.maxInputReportSize(a) > Transport.maxInputReportSize(b)
        }
        guard let dev = devices.first else { throw TransportError.notFound }

        let openRes = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openRes == kIOReturnSuccess else { throw TransportError.openFailed(openRes) }
        device = dev

        IOHIDDeviceRegisterInputReportCallback(
            dev, reportBuffer, 1024,
            { context, _, _, _, reportID, report, reportLength in
                guard let context else { return }
                let transport = Unmanaged<Transport>.fromOpaque(context).takeUnretainedValue()
                transport.handleInput(reportID: UInt8(reportID & 0xFF), report: report, length: Int(reportLength))
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        runLoop = CFRunLoopGetCurrent()
        IOHIDDeviceScheduleWithRunLoop(dev, runLoop!, CFRunLoopMode.defaultMode.rawValue)
    }

    /// USB location of the opened device, to reach its other interfaces.
    var locationID: Int? {
        device.flatMap { IOHIDDeviceGetProperty($0, kIOHIDLocationIDKey as CFString) as? Int }
    }

    static func maxInputReportSize(_ device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, "MaxInputReportSize" as CFString) as? Int) ?? 0
    }

    private func handleInput(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: Int) {
        if ProcessInfo.processInfo.environment["EVEREST_DEBUG"] != nil {
            let raw = (0..<min(length, 24)).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
            stderr(String(format: "cb id=0x%02x len=%d raw=[%@]", reportID, length, raw))
        }
        // The vendor interface uses unnumbered reports: the callback hands
        // back the raw 64-byte packet as the report payload (report ID 0).
        var packet = [UInt8](repeating: 0, count: Transport.packetSize)
        let n = min(length, Transport.packetSize)
        for i in 0..<n { packet[i] = report[i] }
        lock.lock()
        inbox.append(packet)
        if inbox.count > 256 { inbox.removeFirst(inbox.count - 256) }
        lock.unlock()
    }

    private func pop() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        if inbox.isEmpty { return nil }
        return inbox.removeFirst()
    }

    /// Send one 64-byte packet as an unnumbered output report (report ID 0),
    /// so every byte — including the 0x11 header — reaches the device.
    func write(_ packet: [UInt8]) throws {
        guard let device else { throw TransportError.notFound }
        var data = packet
        while data.count < Transport.packetSize { data.append(0) }
        let res = data.withUnsafeMutableBufferPointer { buf -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buf.baseAddress!, buf.count)
        }
        if ProcessInfo.processInfo.environment["EVEREST_DEBUG"] != nil {
            stderr(String(format: "write packet %02x%02x -> 0x%08x", packet[0], packet.count > 1 ? packet[1] : 0, res))
        }
        guard res == kIOReturnSuccess else { throw TransportError.io(res, "setReport(out)") }
    }

    /// Read one 64-byte packet, or nil on timeout. Pumps the run loop so
    /// input callbacks can fire.
    func read(timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let p = pop() { return p }
            if Date() >= deadline { return nil }
            CFRunLoopRunInMode(.defaultMode, min(0.02, max(0, deadline.timeIntervalSinceNow)), true)
        }
    }

    /// Drain any packets already queued.
    func flush() {
        while pop() != nil {}
    }

    /// HID feature report, report ID 0, 64-byte payload.
    func setFeature(_ payload: [UInt8]) throws {
        guard let device else { throw TransportError.notFound }
        var data = payload
        while data.count < 64 { data.append(0) }
        let res = data.withUnsafeMutableBufferPointer { buf -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, buf.baseAddress!, buf.count)
        }
        guard res == kIOReturnSuccess else { throw TransportError.io(res, "setReport(feature)") }
    }

    func getFeature() -> [UInt8] {
        guard let device else { return [] }
        // IOKit writes the report ID into the first byte of the buffer, so ask
        // for 65 bytes and drop it — the payload is the trailing 64.
        var buf = [UInt8](repeating: 0, count: 65)
        var len = 65
        let res = buf.withUnsafeMutableBufferPointer { b -> IOReturn in
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, b.baseAddress!, &len)
        }
        guard res == kIOReturnSuccess else { return [] }
        if ProcessInfo.processInfo.environment["EVEREST_DEBUG"] != nil {
            let raw = buf.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            stderr("getFeature len=\(len) buf=[\(raw)]")
        }
        // IOKit fills the payload from the start of the buffer (no report ID
        // prefix here) and reports len = 65; the report itself is 64 bytes.
        return Array(buf.prefix(64))
    }

    /// Safe to call more than once; also run by `deinit`, so a failed open
    /// (the init throws once every property is set) releases what it took.
    func close() {
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 1024, nil, nil)
            if let runLoop {
                IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
        runLoop = nil
    }

    deinit {
        close()
        reportBuffer.deallocate()
    }
}
