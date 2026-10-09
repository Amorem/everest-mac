import CoreGraphics
import Foundation
import ImageIO
import IOKit
import IOUSBHost

/// Pixel channel of the DisplayPad: interface 1, interrupt OUT endpoint 0x02.
///
/// macOS attaches no HID driver to that interface (it has no IN endpoint), so
/// it is opened as a plain USB interface with IOUSBHost: no root, no kernel
/// extension, no libusb. The open is exclusive, so a session holds it only
/// for the pictures it sends.
final class PadPixelPipe {
    static let interfaceNumber = 1
    static let endpoint = 0x02

    private let interface: IOUSBHostInterface
    private let pipe: IOUSBHostPipe
    private let buffer: NSMutableData

    enum PipeError: Error, CustomStringConvertible, LocalizedError {
        case notFound
        case open(Error)
        var description: String {
            switch self {
            case .notFound: return "DisplayPad picture interface not found"
            case .open(let e): return "DisplayPad picture interface busy or unavailable (\(e.localizedDescription))"
            }
        }
        var errorDescription: String? { description }
    }

    init() throws {
        guard let service = PadPixelPipe.service() else { throw PipeError.notFound }
        defer { IOObjectRelease(service) }
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            pipe = try interface.copyPipe(withAddress: PadPixelPipe.endpoint)
            // Transfers must use a buffer IOUSBHost allocated itself.
            buffer = try interface.ioData(withCapacity: PadProto.pixelChunk)
        } catch {
            throw PipeError.open(error)
        }
    }

    private static func service() -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            func prop(_ k: String) -> Int? {
                IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            if prop("idVendor") == Transport.vendorID, prop("idProduct") == PadProto.productID,
               prop("bInterfaceNumber") == interfaceNumber { return s }
            IOObjectRelease(s)
        }
        return nil
    }

    /// Send a whole stream, 1024 bytes at a time.
    func send(_ bytes: [UInt8]) throws {
        let chunk = PadProto.pixelChunk
        for off in stride(from: 0, to: bytes.count, by: chunk) {
            let n = min(chunk, bytes.count - off)
            bytes.withUnsafeBytes { raw in
                buffer.replaceBytes(in: NSRange(location: 0, length: n), withBytes: raw.baseAddress! + off)
            }
            if n < chunk { buffer.resetBytes(in: NSRange(location: n, length: chunk - n)) }
            var sent = 0
            // Interrupt pipes take no timeout (0 = wait for completion).
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &sent, completionTimeout: 0)
        }
    }

    func close() { interface.destroy() }
}

/// High-level operations on the DisplayPad, synchronous like `Keyboard`.
///
/// Several processes may have the command interface open (app, daemon, CLI):
/// every reply reaches all of them, so replies are matched by their echoed
/// bytes, and key events read while waiting are kept for `nextEvent`.
final class DisplayPad {
    let transport: Transport
    private(set) var firmware: UInt16?
    private var pendingEvents: [[UInt8]] = []

    enum PadError: Error, CustomStringConvertible, LocalizedError {
        case notFound
        case noAnswer
        case unsupportedFirmware(UInt16)
        case refused([UInt8])
        case imageRejected(Int)

        var description: String {
            switch self {
            case .notFound: return "DisplayPad not found (VID:PID 3282:0009)"
            case .noAnswer: return "the DisplayPad did not answer (still starting up, or on an unpowered hub)"
            case .unsupportedFirmware(let v):
                return "DisplayPad firmware \(PadProto.firmwareString(v)) is not supported (tested: \(PadProto.firmwareString(PadProto.supportedFirmware)))"
            case .refused(let p): return String(format: "refused to send command %02x %02x to the DisplayPad", p[0], p[1])
            case .imageRejected(let k): return "the DisplayPad did not take the picture for key \(k + 1)"
            }
        }
        var errorDescription: String? { description }
    }

    /// Cheap presence check that opens nothing.
    static var isPresent: Bool {
        var it: io_iterator_t = 0
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        match["idVendor"] = Transport.vendorID
        match["idProduct"] = PadProto.productID
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        let s = IOIteratorNext(it)
        if s != 0 { IOObjectRelease(s); return true }
        return false
    }

    /// Opens the pad, switches it to host mode and checks its firmware.
    /// `startup` is how long to keep asking: a pad just plugged in needs a
    /// few seconds before it answers.
    init(allowUnsupported: Bool = false, startup: TimeInterval = 8) throws {
        do { transport = try Transport(productID: PadProto.productID) } catch { throw PadError.notFound }
        do {
            try enable(timeout: startup)
            for _ in 0..<3 where firmware == nil {
                firmware = try request(PadProto.firmwareInfo, echo: 2, timeout: 0.8).flatMap(PadProto.firmwareVersion)
            }
            if !allowUnsupported {
                guard let v = firmware else { throw PadError.noAnswer }
                guard v == PadProto.supportedFirmware else { throw PadError.unsupportedFirmware(v) }
            }
        } catch {
            transport.close()
            throw error
        }
    }

    func close() { transport.close() }

    /// Host mode, retried until the pad echoes it.
    func enable(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try request(PadProto.enable, echo: 5, timeout: 0.5) != nil { return }
        } while Date() < deadline
        throw PadError.noAnswer
    }

    func send(_ p: [UInt8]) throws {
        guard PadProto.isAllowed(p) else { throw PadError.refused(p) }
        try transport.write(p)
    }

    /// Send and wait for the reply that echoes the first `echo` bytes. One
    /// request at a time: the pad has a single command buffer.
    func request(_ p: [UInt8], echo: Int, timeout: TimeInterval) throws -> [UInt8]? {
        try send(p)
        return wait(prefix: Array(p.prefix(echo)), timeout: timeout)
    }

    private func wait(prefix: [UInt8], timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while let r = transport.read(timeout: max(0.01, deadline.timeIntervalSinceNow)) {
            if r.starts(with: prefix) { return r }
            if PadProto.isKeyEvent(r) { pendingEvents.append(r) }
            if Date() >= deadline { break }
        }
        return nil
    }

    /// The next key event (pressed keys, empty = all released), or nil.
    func nextEvent(timeout: TimeInterval) -> Set<Int>? {
        if !pendingEvents.isEmpty { return PadProto.pressedKeys(pendingEvents.removeFirst()) }
        let deadline = Date().addingTimeInterval(timeout)
        while let r = transport.read(timeout: max(0.01, deadline.timeIntervalSinceNow)) {
            if PadProto.isKeyEvent(r) { return PadProto.pressedKeys(r) }
            if Date() >= deadline { break }
        }
        return nil
    }

    func brightness() throws -> Int? {
        try request(PadProto.brightnessQuery, echo: 2, timeout: 0.6).flatMap(PadProto.brightness)
    }

    func setBrightness(_ percent: Int) throws {
        _ = try request(PadProto.setBrightness(percent), echo: 2, timeout: 0.6)
    }

    /// Pictures for several keys (BGR, 102 × 102), in RAM. Opens the pixel
    /// interface once for the batch.
    func setKeyImages(_ images: [(key: Int, bgr: [UInt8])]) throws {
        guard !images.isEmpty else { return }
        let pipe = try openPipe()
        defer { pipe.close() }
        for (key, bgr) in images {
            guard try request(PadProto.keyImage(key), echo: 2, timeout: 1).map(PadProto.isImageReady) == true else {
                throw PadError.imageRejected(key)
            }
            try pipe.send(PadProto.pixelStream(bgr: bgr))
            guard wait(prefix: [0x21, 0x00, 0xFF], timeout: 1.5).map(PadProto.isImageDone) == true else {
                throw PadError.imageRejected(key)
            }
        }
    }

    func setKeyImage(_ key: Int, bgr: [UInt8]) throws { try setKeyImages([(key, bgr)]) }

    /// Another program (app or daemon) may be sending pictures: wait for it.
    private func openPipe() throws -> PadPixelPipe {
        var last: Error = PadPixelPipe.PipeError.notFound
        for _ in 0..<20 {
            do { return try PadPixelPipe() } catch { last = error }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw last
    }
}

extension ImageTools {
    /// An image file at the pad's key size, BGR (black where transparent).
    static func padBGR(path: String) throws -> [UInt8] {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw ImageError.cannotOpen(path)
        }
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImageError.cannotDecode(path) }
        // Square crop from the centre, so nothing is stretched.
        let side = min(image.width, image.height)
        let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                               width: side, height: side)) ?? image
        return try padBGR(image: square)
    }

    static func padBGR(image: CGImage) throws -> [UInt8] {
        let side = PadProto.keySide
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { throw ImageError.cannotDecode("bitmap context") }
        var out = [UInt8](repeating: 0, count: side * side * 3)
        for i in 0..<(side * side) {
            out[i * 3] = rgba[i * 4 + 2]
            out[i * 3 + 1] = rgba[i * 4 + 1]
            out[i * 3 + 2] = rgba[i * 4]
        }
        return out
    }
}
