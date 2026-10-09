import Foundation

/// Everest Max wire protocol (vendor interface 3, 64-byte packets).
/// Reverse-engineered by the BaseCamp-Linux project and re-verified against
/// this unit. Byte offsets below are documented so the packet dumps in the
/// code stay readable.
enum Proto {
    static let packetSize = 64

    static func packet(_ bytes: [UInt8], at: [Int: [UInt8]] = [:]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetSize)
        for (i, b) in bytes.enumerated() where i < packetSize { p[i] = b }
        for (offset, vals) in at {
            for (i, b) in vals.enumerated() where offset + i < packetSize { p[offset + i] = b }
        }
        return p
    }

    // MARK: - Session

    /// Keepalive / state read. The reply carries button events and the current
    /// display configuration (device bytes at 7..9, dial mode at 10).
    static var keepalive: [UInt8] { packet([0x11, 0x14]) }
    /// Interface re-init.
    static var reinit: [UInt8] { packet([0x11, 0x12]) }

    // MARK: - Clock

    /// 11 80 00 00 01 — announce a time update.
    static var timeAnnounce: [UInt8] { packet([0x11, 0x80, 0x00, 0x00, 0x01]) }
    /// 11 84 00 00 — open the time sync.
    static var timeOpen: [UInt8] { packet([0x11, 0x84, 0x00, 0x00]) }

    /// 11 84 00 01 00 00 MM DD HH MM SS STYLE
    static func timeSet(month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8, style: UInt8) -> [UInt8] {
        packet([0x11, 0x84, 0x00, 0x01, 0x00, 0x00, month, day, hour, minute, second, style])
    }

    // MARK: - Monitor values

    /// 11 81 <index> 00 <value>. index: 0 cpu, 1 gpu, 2 hdd, 3 network MB/s, 4 ram.
    static func metric(index: UInt8, value: UInt8) -> [UInt8] {
        packet([0x11, 0x81, index, 0x00, value])
    }

    /// 11 83 00 00 <level> — volume readout on the dial.
    static func volume(level: UInt8) -> [UInt8] {
        packet([0x11, 0x83, 0x00, 0x00, level])
    }

    // MARK: - Main display mode

    enum MainMode: String, CaseIterable {
        case image, clock, volume, cpu, gpu, hd, network, ram, apm

        var menuByte: UInt8 {
            switch self {
            case .image: return 0x01
            case .clock: return 0x11
            case .volume: return 0x71
            case .cpu: return 0x91
            case .gpu: return 0xA1
            case .hd: return 0xB1
            case .network: return 0xC1
            case .ram: return 0xD1
            case .apm: return 0xE1
            }
        }
    }

    /// Full mode-switch packet (11 14 with the write flag and the device's own
    /// bytes echoed back — the firmware rejects foreign values there).
    static func modeSwitch(deviceBytes: [UInt8], mode: MainMode) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: packetSize)
        p[0] = 0x11; p[1] = 0x14
        p[3] = 0x01; p[4] = 0x02; p[5] = 0xFF
        let db = deviceBytes.count == 3 ? deviceBytes : [0xF3, 0xCC, 0x23]
        p[7] = db[0]; p[8] = db[1]; p[9] = db[2]
        p[10] = mode.menuByte
        p[11] = 0x1E; p[13] = 0x1E; p[15] = 0x01
        p[16] = 0x12; p[17] = 0x13; p[18] = 0x14; p[19] = 0x15
        p[20] = 0x02; p[22] = 0x32
        return p
    }

    /// The `11 14` settings block written back with new display brightness
    /// bytes (SDKDLL `SetExtendInfo`): the reply to `11 14 00 00` echoed with
    /// the write flag, bytes 23–32 replaced. They are five (dial, numpad)
    /// pairs, one per lighting slot: `00` = follow the lighting brightness,
    /// `80 | v` = fixed v % (rounded to 0/25/50/75/100 by the firmware).
    /// Base Camp writes `80 80` when a profile's lighting is Off. A settings
    /// write, not a picture or sector write; no SaveFlash follows it.
    static func displayBrightness(from settings: [UInt8], byte: UInt8) -> [UInt8]? {
        guard settings.count >= 33, settings[0] == 0x11, settings[1] == 0x14 else { return nil }
        var p = Array(settings.prefix(packetSize))
        while p.count < packetSize { p.append(0) }
        p[2] = 0x00
        p[3] = 0x01
        for i in 23...32 { p[i] = byte }
        return p
    }

    /// Display brightness bytes: dark (fixed 0 %), or following the lighting
    /// as the mode switch above leaves them.
    static let displaysOff: UInt8 = 0x80
    static let displaysFollowLighting: UInt8 = 0x00

    /// 13 41 00 00 01 — reset the dial picture to the factory logo.
    static var resetDial: [UInt8] { packet([0x13, 0x41, 0x00, 0x00, 0x01]) }

    // MARK: - Button icons and flash actions

    /// Built-in icon id: 0x40 + button*9 + variant (variant 0..8).
    static func iconID(button: Int, variant: Int) -> UInt8 {
        UInt8(0x40 + button * 9 + variant)
    }

    /// 11 00 / 11 02 00 01 01 <iid> 02 — select a built-in icon.
    static var iconSelectPrefix: [UInt8] { packet([0x11, 0x00]) }
    static func iconSelect(iid: UInt8) -> [UInt8] {
        packet([0x11, 0x02, 0x00, 0x01, 0x01, iid, 0x02])
    }

    /// 12 08 00 <btn+1> — select the flash slot for an action write.
    static func actionSlot(button: Int) -> [UInt8] {
        packet([0x12, 0x08, 0x00, UInt8(button + 1)])
    }

    /// 17 AA <total_len> 00 <type> <command> — the action payload.
    /// type: 0x02 url/browser, 0x04 shell.
    static func actionData(_ command: String, type: UInt8) -> [UInt8] {
        let bytes = Array(command.utf8.prefix(55))
        var p = [UInt8](repeating: 0, count: packetSize)
        p[0] = 0x17; p[1] = 0xAA
        p[2] = UInt8(1 + bytes.count)
        p[3] = 0x00
        p[4] = type
        for (i, b) in bytes.enumerated() { p[5 + i] = b }
        return p
    }

    // MARK: - RGB

    /// 13 55 00 00 06 — commit custom lighting to flash slot 6.
    static var rgbPersist: [UInt8] { packet([0x13, 0x55, 0x00, 0x00, 0x06]) }

    // MARK: - Recovery (SDKDLL exports)

    /// 13 40 00 00 <arg> — ResetFlash.
    static func resetFlash(_ arg: UInt8) -> [UInt8] { packet([0x13, 0x40, 0x00, 0x00, arg]) }
    /// 13 41 00 00 <arg> — ResetMMDockPic (dial picture).
    static func resetDockPic(_ arg: UInt8) -> [UInt8] { packet([0x13, 0x41, 0x00, 0x00, arg]) }
    /// 13 42 00 00 <slot1> … <slot5> — ResetNumpadPic: one key bitmap per
    /// image slot (bit n = Dn+1; 0x0f = all four keys).
    static func resetNumpadPics(_ bitmap: UInt8, slot: Int = 1) -> [UInt8] {
        var p = packet([0x13, 0x42, 0x00, 0x00])
        p[4 + max(0, min(4, slot - 1))] = bitmap
        return p
    }

    // MARK: - Key remapping (protocol doc §4)

    /// 14 20 <key> 00 <newkey> — redefine a key on the current profile.
    /// Key codes are physical matrix positions (see KeyCodes).
    static func remapKey(_ key: UInt8, to newKey: UInt8) -> [UInt8] {
        packet([0x14, 0x20, key, 0x00, newKey])
    }

    /// 14 21 <key> 00 <newkey> <modifiers> — remap with modifier bitmask.
    static func remapKeyWithModifiers(_ key: UInt8, to newKey: UInt8, modifiers: UInt8) -> [UInt8] {
        packet([0x14, 0x21, key, 0x00, newKey, modifiers])
    }

    // MARK: - Image upload (feature reports)

    /// `aa 55 21 <dest>` — set the image destination. 0x03 dial, 0x04 display keys.
    static func destSelect(dest: UInt8) -> [UInt8] { [0xAA, 0x55, 0x21, dest] }
    /// `aa 55 22 00` — confirm/query the current destination.
    static let destQuery: [UInt8] = [0xAA, 0x55, 0x22, 0x00]
    /// `aa 55 7f` — the SDK's device reset (SDKDLL ResetDevice).
    static func deviceReset() -> [UInt8] { [0xAA, 0x55, 0x7F] }

    /// `aa 55 10 sl sm sh clow chigh 00 00 02 profile ledno` (§6.4).
    /// size is little-endian 3 bytes; `ledno` is the 0-based target (D1 = 0;
    /// the dial uses 0) and `profile` the image slot — per the Windows capture.
    static func uploadDescriptor(size: Int, checksum: UInt16, profile: UInt8, ledno: UInt8) -> [UInt8] {
        [0xAA, 0x55, 0x10,
         UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF),
         UInt8(checksum & 0xFF), UInt8(checksum >> 8),
         0x00, 0x00, 0x02, profile, ledno]
    }
}

/// The keyboard's current report (reply to the 0x11 0x14 keepalive).
struct DeviceState {
    let raw: [UInt8]

    init(raw: [UInt8]) {
        self.raw = raw
    }

    /// Bytes 7..9 — the firmware's own configuration cipher, echoed back when
    /// switching display modes.
    var deviceBytes: [UInt8] {
        let b = Array(raw[7..<10])
        return b.contains(where: { $0 != 0 }) ? b : [0xF3, 0xCC, 0x23]
    }

    /// Byte 10 — current dial menu (0x01 image, 0x11 clock, ...).
    var modeByte: UInt8 { raw.count > 10 ? raw[10] : 0x00 }

    /// FW_EXTEND_INFO (from the Windows SDK, offsets documented by the
    /// BaseCamp-Linux probe): the keyboard's own account of what is attached.
    /// The 29-byte body starts at byte 4.
    private var body: ArraySlice<UInt8> { raw.count >= 33 ? raw[4..<33] : raw[0..<0] }

    var mmDockPlugged: Bool { body.count > 0 && body[body.startIndex] != 0 }
    var numpadPlugged: Bool { body.count > 16 && body[body.startIndex + 16] != 0 }
    /// body[7..9] as little-endian u16.
    var screensaverSeconds: Int {
        guard body.count > 9 else { return 0 }
        return Int(body[body.startIndex + 7]) | (Int(body[body.startIndex + 8]) << 8)
    }
    var turnOffSeconds: Int {
        guard body.count > 11 else { return 0 }
        return Int(body[body.startIndex + 9]) | (Int(body[body.startIndex + 10]) << 8)
    }

    var attachedSummary: String {
        let dock = mmDockPlugged, numpad = numpadPlugged
        switch (dock, numpad) {
        case (true, true): return "numpad + media dock (full Everest Max)"
        case (true, false): return "media dock only"
        case (false, true): return "numpad only"
        case (false, false): return "base only (Everest Core)"
        }
    }

    /// Button byte in a 0x01 event report: bits for D1..D4 on offset 42.
    static func pressedButton(in packet: [UInt8]) -> Int? {
        guard packet.count > 42, packet[0] == 0x01 else { return nil }
        switch packet[42] {
        case 0x02: return 0
        case 0x04: return 1
        case 0x08: return 2
        case 0x10: return 3
        default: return nil
        }
    }
}
