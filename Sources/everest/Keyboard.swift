import Foundation

/// High-level operations on the keyboard. Every method is synchronous and
/// leaves the HID session usable for the next call.
final class Keyboard {
    let transport: Transport
    /// Firmware layout code, read by `wake()`.
    private(set) var layoutCode: Int?
    /// Firmware version byte (BCD-like: 0x57 is firmware 57), read at open.
    private(set) var firmwareVersion: UInt8?

    /// The only firmware this code has been tested on. Anything else — older
    /// *or* newer — is refused: the picture and flash protocol is the same
    /// one the firmware update uses, and a wrong guess could brick a keyboard.
    static let supportedFirmware: UInt8 = 0x57

    static func isSupported(firmware: UInt8) -> Bool { firmware == supportedFirmware }

    /// Why a keyboard was not opened.
    enum OpenError: Error, CustomStringConvertible, LocalizedError {
        case unsupportedFirmware(UInt8)
        /// The keyboard did not say which firmware it runs: not trusted.
        case firmwareUnreadable

        var description: String {
            switch self {
            case .unsupportedFirmware(let v):
                return "firmware \(String(format: "%x", v)) is not supported (tested: \(String(format: "%x", Keyboard.supportedFirmware))) — "
                    + "update the keyboard with Mountain's Base Camp on Windows, then reconnect it"
            case .firmwareUnreadable:
                return "the keyboard did not report its firmware version, so it is left alone"
            }
        }

        var errorDescription: String? { description }
    }

    /// Opens the keyboard **only if it runs the tested firmware**; otherwise
    /// throws without sending anything but read-only queries (`11 12`, `11 00`).
    /// `allowUnsupported` is for read-only callers that must be able to
    /// report the version (the status display, `everest info`).
    init(allowUnsupported: Bool = false) throws {
        transport = try Transport()
        do {
            try verifyFirmware(allowUnsupported: allowUnsupported)
        } catch {
            transport.close()
            throw error
        }
    }

    private func verifyFirmware(allowUnsupported: Bool) throws {
        wake()
        var version: UInt8?
        for _ in 0..<3 where version == nil {
            transport.flush()
            try? transport.write(Proto.packet([0x11, 0x00]))
            if let r = waitReply(0x00, timeout: 0.8), r.count > 4 { version = r[4] }
        }
        firmwareVersion = version
        if allowUnsupported { return }
        guard let version else { throw OpenError.firmwareUnreadable }
        guard Keyboard.isSupported(firmware: version) else { throw OpenError.unsupportedFirmware(version) }
    }

    func close() { transport.close() }

    /// The answer to command `0x11 <cmd>`. The keyboard sends every answer to
    /// every program that has the HID device open (the daemon's keep-alives
    /// included), so the next packet is not necessarily the one asked for.
    func waitReply(_ cmd: UInt8, timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let p = transport.read(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { return nil }
            if p.count > 1, p[0] == 0x11, p[1] == cmd { return p }
        }
        return nil
    }

    // MARK: - Session helpers

    /// Wake the vendor channel: the firmware answers 11 12/11 14 once ready.
    func wake() {
        try? transport.write(Proto.reinit)
        // The `11 12` answer carries the layout code at byte 4 (GetFWLayout).
        if let p = waitReply(0x12, timeout: 0.6), p.count > 4 { layoutCode = Int(p[4]) }
        try? transport.write(Proto.keepalive)
        _ = transport.read(timeout: 0.3)
        transport.flush()
    }

    /// Ask for the current state packet (reply to the keepalive). Button
    /// events (0x01) and display-refresh notifications (ff aa) share the
    /// channel, so skip them until the real answer turns up.
    func state() -> DeviceState? {
        try? transport.write(Proto.keepalive)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            guard let p = transport.read(timeout: 0.4) else { return nil }
            if p[0] == 0x11 && p.count > 1 && p[1] == 0x14 { return DeviceState(raw: p) }
            // 0x01 = button/key event, 0xff 0xaa = display refreshed
        }
        return nil
    }

    // MARK: - Clock

    func setTime(style: UInt8, twelveHour: Bool, date: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        var hour = c.hour ?? 0
        if twelveHour { hour = hour % 12 == 0 ? 12 : hour % 12 }
        try? transport.write(Proto.timeAnnounce)
        _ = transport.read(timeout: 0.3)
        try? transport.write(Proto.timeOpen)
        _ = transport.read(timeout: 0.3)
        try? transport.write(Proto.timeSet(month: UInt8(c.month ?? 1), day: UInt8(c.day ?? 1),
                                           hour: UInt8(hour), minute: UInt8(c.minute ?? 0),
                                           second: UInt8(c.second ?? 0), style: style))
        _ = transport.read(timeout: 0.3)
    }

    // MARK: - Main display

    func setMainMode(_ mode: Proto.MainMode) {
        let deviceBytes = state()?.deviceBytes ?? [0xF3, 0xCC, 0x23]
        try? transport.write(Proto.modeSwitch(deviceBytes: deviceBytes, mode: mode))
        _ = transport.read(timeout: 0.5)
    }

    func resetDial() {
        try? transport.write(Proto.resetDial)
        _ = transport.read(timeout: 0.5)
    }

    func sendMetric(index: UInt8, value: UInt8) {
        try? transport.write(Proto.metric(index: index, value: value))
        _ = transport.read(timeout: 0.15)
    }

    func sendVolume(_ level: UInt8) {
        try? transport.write(Proto.volume(level: level))
        _ = transport.read(timeout: 0.15)
    }

    // MARK: - Built-in icons / flash actions

    /// Select one of the built-in icon glyphs on a numpad button.
    func setIcon(button: Int, variant: Int) {
        try? transport.write(Proto.iconSelectPrefix)
        _ = transport.read(timeout: 0.2)
        try? transport.write(Proto.iconSelect(iid: Proto.iconID(button: button, variant: variant)))
        drainIconReply()
    }

    private func drainIconReply() {
        while let p = transport.read(timeout: 0.2) {
            if p[0] == 0x01 { break }
            if p.count >= 5 && p[4] == 0x00 { break }
        }
    }

    /// Store a host action in the keyboard flash slots. `command` is what the
    /// Windows software would run when the button is pressed; the flash write
    /// also arms the button's event reporting (byte 42), which the daemon
    /// relies on.
    func writeAction(button: Int, command: String, type: UInt8 = 0x04) {
        try? transport.write(Proto.actionSlot(button: button))
        _ = transport.read(timeout: 0.2)
        try? transport.write(Proto.actionData(command, type: type))
        _ = transport.read(timeout: 0.2)
    }

    /// Replace the keyboard's own D1–D4 actions with a no-op. Without this the
    /// firmware also sends its stored shortcut when a key is pressed (factory
    /// values come back after a picture reset, `13 42`), on top of whatever the
    /// app or the daemon runs. Writing also arms the key-event reports the
    /// daemon relies on.
    func neutraliseKeyActions() {
        for i in 0..<4 { writeAction(button: i, command: ":") }
    }

    // MARK: - Image upload

    static let iconW = 72, iconH = 72
    static let mainW = 240, mainH = 204

    /// Transfer response layout (protocol doc §6.4/§6.5):
    /// `aa 55 10 fa <size lo> <size mid> <size hi> ... [fe]` — the byte count
    /// received so far is a 3-byte little-endian value at offset 4, and the
    /// final ack carries 0xfe.
    private func transferAck(_ r: [UInt8]) -> (ok: Bool, received: Int, complete: Bool)? {
        guard r.count >= 10, r[0] == 0xAA, r[1] == 0x55, r[2] == 0x10 else { return nil }
        let received = Int(r[4]) | (Int(r[5]) << 8) | (Int(r[6]) << 16)
        return (r[3] == 0xFA, received, r[9] == 0xFE)
    }

    /// `aa 55 21 <target>` then `aa 55 22 00`, as SDKDLL's StartPicUpdate does
    /// (target 0x03 = dial image, 0x04 = display keys). Both must answer `fa`.
    /// This only selects the target — it does not erase anything.
    private func selectTarget(_ target: UInt8) -> Bool {
        for step in [Proto.destSelect(dest: target), Proto.destQuery] {
            var ok = false
            for _ in 0..<40 {
                try? transport.setFeature(step)
                usleep(80_000)
                let r = transport.getFeature()
                if r.count >= 4, r[0] == 0xAA, r[1] == 0x55, r[2] == step[2], r[3] == 0xFA { ok = true; break }
                usleep(120_000)
            }
            if !ok { return false }
        }
        return true
    }

    /// Send the upload descriptor until the keyboard accepts it.
    ///
    /// SDKDLL (`fcn.1000c2a0`) **re-sends the descriptor on every `fb`
    /// ("busy") reply** and checks again ~0.3 s later: while the keyboard
    /// erases the old picture it answers `fb`, and the next send after it is
    /// ready gets `fa`. Sending once and waiting (what this code used to do)
    /// only succeeded on the next full retry, 15–50 s later. `fe` means the
    /// request itself was rejected, so stop.
    private func descriptorAccepted(_ descriptor: [UInt8], timeout: Double,
                                    progress: ((Double) -> Void)?) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try? transport.setFeature(descriptor)
            usleep(150_000)
            let r = transport.getFeature()
            if r.count >= 4, r[0] == 0xAA, r[1] == 0x55, r[2] == 0x10 {
                if r[3] == 0xFA { return true }
                if r[3] == 0xFE { return false }
            }
            progress?(Date().timeIntervalSince(start))
            usleep(150_000)
        }
        return false
    }

    /// Stream the image chunks, following the running byte count the device
    /// reports. Never exits early: an abandoned transfer leaves the keyboard
    /// waiting for data.
    private func streamChunks(_ image: [UInt8], range: ClosedRange<Int> = 52...97,
                              progress: ((Int) -> Void)?) -> Bool {
        let total = image.count
        var offset = 0
        var stalls = 0
        let span = Double(range.upperBound - range.lowerBound)
        while offset < total {
            let end = min(offset + 64, total)
            var chunk = Array(image[offset..<end])
            if chunk.count < 64 { chunk.append(contentsOf: [UInt8](repeating: 0, count: 64 - chunk.count)) }
            try? transport.setFeature(chunk)
            usleep(30_000)
            let r = transport.getFeature()
            guard let ack = transferAck(r) else { continue }
            if ack.ok, ack.received > offset {
                offset = ack.received
                stalls = 0
                progress?(range.lowerBound + Int(Double(min(offset, total)) * span / Double(total)))
                if ack.complete { break }
            } else {
                stalls += 1
                if stalls > 600 { return false }   // resend the same chunk on fb
            }
        }
        // The final ack carries 0xfe once the flash commit is done.
        for _ in 0..<40 {
            usleep(100_000)
            if let ack = transferAck(transport.getFeature()), ack.complete { return true }
        }
        return offset >= total
    }

    /// Upload a 72×72 image to a display key (D1…D4 = 0…3).
    ///
    /// The sequence is SDKDLL's `StartPicUpdate`: select the key target,
    /// confirm it, send the descriptor until accepted, stream the chunks.
    /// Descriptor: `aa 55 10 <size:3 LE> <chk:2 LE> 00 00 02 <slot> <key 0…3>`.
    /// The key index is 0-based, and the keyboard erases the old picture
    /// itself — there is no host-side erase.
    ///
    /// Progress: 0–50 preparing (time-based, the keyboard reports nothing),
    /// 52–97 transfer, 100 done.
    func uploadIcon(button: Int, image: [UInt8], slot: Int = 1, progress: ((Int) -> Void)? = nil) throws {
        let expected = Keyboard.iconW * Keyboard.iconH * 2
        guard image.count == expected else {
            throw NSError(domain: "everest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "icon payload must be \(expected) bytes"])
        }
        guard (0...3).contains(button) else {
            throw NSError(domain: "everest", code: 1, userInfo: [NSLocalizedDescriptionKey: "button must be 0…3"])
        }
        guard (1...5).contains(slot) else {
            throw NSError(domain: "everest", code: 3, userInfo: [NSLocalizedDescriptionKey: "profile must be 1…5"])
        }
        // Keep the daemon off the vendor channel for the whole transfer.
        FlashBusy.set()
        defer { FlashBusy.clear() }

        // The flash session wants the vendor channel awake.
        try transport.write(Proto.reinit)
        _ = transport.read(timeout: 0.5)
        for _ in 0..<3 {
            try transport.write(Proto.keepalive)
            _ = transport.read(timeout: 0.3)
            usleep(50_000)
        }
        progress?(2)

        guard selectTarget(0x04) else {
            throw NSError(domain: "everest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: tr("keyboardError.selectTarget")])
        }
        progress?(5)

        var chk: UInt16 = 0
        for b in image { chk &+= UInt16(b) }
        let descriptor = Proto.uploadDescriptor(size: image.count, checksum: chk,
                                                profile: UInt8(slot), ledno: UInt8(button))
        // Time-based progress while the keyboard prepares the slot: eases
        // toward 50 and never claims more.
        let accepted = descriptorAccepted(descriptor, timeout: 90) { t in
            progress?(5 + Int(45 * (1 - exp(-t / 8))))
        }
        guard accepted else {
            throw NSError(domain: "everest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: tr("keyboardError.refused")])
        }
        progress?(52)
        guard streamChunks(image, range: 52...97, progress: progress) else {
            throw NSError(domain: "everest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: tr("keyboardError.interrupted")])
        }
        // Numpad refresh signal on the interrupt channel.
        try? transport.write(Proto.keepalive)
        for _ in 0..<20 {
            if let p = transport.read(timeout: 0.2), p.count >= 2, p[0] == 0xFF, p[1] == 0xAA { break }
        }
        progress?(100)
    }

    /// Upload a 240×204 image to the main dial display.
    func uploadMainDisplay(image: [UInt8], progress: ((Int) -> Void)? = nil) throws {
        let expected = Keyboard.mainW * Keyboard.mainH * 2
        guard image.count == expected else {
            throw NSError(domain: "everest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "main display payload must be \(expected) bytes"])
        }
        FlashBusy.set()
        defer { FlashBusy.clear() }
        setMainMode(.image)
        var chk: UInt16 = 0
        for b in image { chk &+= UInt16(b) }
        let desc = Proto.uploadDescriptor(size: image.count, checksum: chk, profile: 1, ledno: 0)
        // The device often refuses the first descriptors; resend it between
        // polls (the Windows capture shows the same) and retry the handshake.
        var accepted = false
        for _ in 0..<6 {
            try? transport.setFeature(Proto.destSelect(dest: 0x03))
            usleep(150_000)
            _ = transport.getFeature()
            try? transport.setFeature(Proto.destQuery)
            usleep(150_000)
            _ = transport.getFeature()
            for _ in 0..<5 {
                try? transport.setFeature(desc)
                usleep(200_000)
                let r = transport.getFeature()
                if r.count >= 4 && r[2] == 0x10 && r[3] == 0xFA { accepted = true; break }
            }
            if accepted { break }
        }
        guard accepted else {
            throw NSError(domain: "everest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: tr("keyboardError.dialRefused")])
        }
        progress?(5)
        guard streamChunks(image, progress: progress) else {
            throw NSError(domain: "everest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: tr("keyboardError.dialIncomplete")])
        }
    }

    // MARK: - Recovery

    /// Clear a wedged flash session: the SDK's device reset plus the picture
    /// resets, then bring the vendor channel back up.
    func recover() {
        try? transport.setFeature(Proto.deviceReset())
        usleep(100_000)
        try? transport.write(Proto.resetFlash(0x01))
        _ = transport.read(timeout: 0.5)
        try? transport.write(Proto.resetDockPic(0x01))
        _ = transport.read(timeout: 0.5)
        try? transport.write(Proto.resetNumpadPics(0x0F))
        _ = transport.read(timeout: 0.5)
        try? transport.write(Proto.reinit)
        _ = transport.read(timeout: 0.5)
    }

    // MARK: - Firmware key remap

    /// Redefine a physical key on the current profile (§4). `key` and `to`
    /// are matrix codes from KeyCodes.
    func remapKey(_ key: UInt8, to newKey: UInt8, modifiers: UInt8? = nil) {
        if let modifiers {
            try? transport.write(Proto.remapKeyWithModifiers(key, to: newKey, modifiers: modifiers))
        } else {
            try? transport.write(Proto.remapKey(key, to: newKey))
        }
        _ = transport.read(timeout: 0.5)
    }

}
