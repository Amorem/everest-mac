import Foundation

/// Packets for the Mountain DisplayPad (3282:0009), as pure functions so the
/// tests can pin them byte for byte. Source: Mountain's MIT-licensed
/// DisplayPad SDK (disassembled) and packets verified on hardware; see
/// `docs/DISPLAYPAD.md`.
///
/// The pad is a separate USB device with its own firmware: twelve keys, each
/// a 102 × 102 window on one 800 × 240 panel. Commands are 64-byte packets on
/// interface 3 (vendor collection 0xFF00/1, like the keyboard); pixels go to
/// interface 1 in 1024-byte chunks. A reply echoes the first bytes of its
/// request, `ff aa` is an error and a packet starting with `01` is a key event.
enum PadProto {
    static let productID = 0x0009
    static let keyCount = 12
    static let columns = 6
    static let keySide = 102
    /// Firmware this code was tested with (`11 00` reply, bytes 4–5, BCD).
    static let supportedFirmware: UInt16 = 0x0008

    static let pixelChunk = 1024
    static let pixelChunks = 31
    /// 102 × 102 × 3 bytes, announced to the pad as 512-byte blocks.
    static var keyImageBytes: Int { keySide * keySide * 3 }
    static var keyImageBlocks: Int { (keyImageBytes + 511) / 512 }

    static func packet(_ head: [UInt8]) -> [UInt8] {
        head + [UInt8](repeating: 0, count: max(0, Transport.packetSize - head.count))
    }

    // MARK: Commands

    /// Host mode ("APEnable"): the pad shows nothing, not even its logo, until
    /// it gets this. The reply echoes bytes 0–4; a fresh pad can take a few
    /// seconds (and an `ff aa`) before it answers.
    static let enable = packet([0x11, 0x80, 0x00, 0x00, 0x01])
    static let firmwareInfo = packet([0x11, 0x00])
    static let brightnessQuery = packet([0x12, 0x00, 0x00, 0x01])
    static let sleepQuery = packet([0x22, 0x00, 0x00, 0x01])

    static func brightnessLevel(_ percent: Int) -> Int { max(0, min(100, percent)) }

    /// On firmware 8 the backlight command is stored and read back but the
    /// screen stays at full brightness unless it is 0 (checked on hardware:
    /// keys drawn at 5 % and 100 % looked the same). Brightness is therefore
    /// done by darkening the pictures, and the backlight is only on or off.
    static func backlight(for percent: Int) -> Int { percent > 0 ? 100 : 0 }

    /// A picture scaled to `percent` of its brightness.
    static func dim(_ bgr: [UInt8], percent: Int) -> [UInt8] {
        let p = brightnessLevel(percent)
        guard p < 100 else { return bgr }
        return bgr.map { UInt8((Int($0) * p + 50) / 100) }
    }

    static func setBrightness(_ percent: Int) -> [UInt8] {
        packet([0x12, 0x03, 0x00, 0x00, UInt8(brightnessLevel(percent))])
    }

    /// Picture for one key, in RAM (lost when the pad loses power; nothing is
    /// written to its flash): mode 0, key, block count, then the window
    /// (left, top, right, bottom) inside the key.
    static func keyImage(_ key: Int) -> [UInt8] {
        let last = UInt8(keySide - 1)
        return packet([0x21, 0x00, 0x00, 0x00, UInt8(key), UInt8(keyImageBlocks), 0x00, 0x00, last, last])
    }

    /// What may be sent at all. Everything else, firmware update (`30 aa 55`),
    /// sector writes and erases (`1a`, `1b`, `13 xx`) and flash pictures
    /// (`21 01`, `21 02`) included, is refused before it reaches the pad.
    static func isAllowed(_ p: [UInt8]) -> Bool {
        guard p.count == Transport.packetSize else { return false }
        if p == enable || p == firmwareInfo || p == brightnessQuery || p == sleepQuery { return true }
        if p[0] == 0x12, p[1] == 0x03, p[2] == 0, p[3] == 0, p[4] <= 100 {
            return p[5...].allSatisfy { $0 == 0 }
        }
        if p[0] == 0x21, p[1] == 0x00, (0..<keyCount).contains(Int(p[4])) { return p == keyImage(Int(p[4])) }
        return false
    }

    // MARK: Replies

    static func isError(_ reply: [UInt8]) -> Bool { reply.count >= 2 && reply[0] == 0xFF && reply[1] == 0xAA }
    static func isKeyEvent(_ reply: [UInt8]) -> Bool { reply.first == 0x01 }

    static func firmwareVersion(_ reply: [UInt8]) -> UInt16? {
        guard reply.count >= 6, reply[0] == 0x11, reply[1] == 0x00 else { return nil }
        return UInt16(reply[4]) | UInt16(reply[5]) << 8
    }

    /// BCD firmware version as printed ("8", "12"…).
    static func firmwareString(_ v: UInt16) -> String { String(v, radix: 16) }

    static func brightness(_ reply: [UInt8]) -> Int? {
        guard reply.count >= 6, reply[0] == 0x12, reply[1] == 0x00 else { return nil }
        return Int(reply[5])
    }

    /// `21 00 00` = ready for pixels, `21 00 ff ff` = picture shown.
    static func isImageReady(_ reply: [UInt8]) -> Bool { reply.count >= 3 && reply[0] == 0x21 && reply[1] == 0 && reply[2] == 0 }
    static func isImageDone(_ reply: [UInt8]) -> Bool { reply.count >= 4 && reply[0] == 0x21 && reply[1] == 0 && reply[2] == 0xFF && reply[3] == 0xFF }

    /// Keys held down in a key-event packet (0-based, left to right, top row
    /// first): byte 42 bits 0x02…0x80 are keys 0–6, byte 47 bits 0x01…0x10
    /// keys 7–11. A release sends the packet with no bit set.
    static func pressedKeys(_ p: [UInt8]) -> Set<Int> {
        guard isKeyEvent(p), p.count >= 48 else { return [] }
        var keys = Set<Int>()
        for k in 0..<7 where p[42] & (0x02 << k) != 0 { keys.insert(k) }
        for k in 0..<5 where p[47] & (0x01 << k) != 0 { keys.insert(7 + k) }
        return keys
    }

    // MARK: Pixels

    /// The stream sent after `keyImage`: BGR from byte 0 (no header, unlike
    /// the community drivers: with their 306 leading zeros the bottom row is
    /// lost), padded to 31 chunks of 1024 bytes.
    static func pixelStream(bgr: [UInt8]) -> [UInt8] {
        let total = pixelChunk * pixelChunks
        var out = Array(bgr.prefix(keyImageBytes))
        out += [UInt8](repeating: 0, count: total - out.count)
        return out
    }

    static func solid(r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(keyImageBytes)
        for _ in 0..<(keySide * keySide) { out += [b, g, r] }
        return out
    }
}
