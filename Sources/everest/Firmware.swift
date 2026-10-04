import Foundation

/// The keyboard's built-in lighting — the effects Base Camp offers, encoded
/// exactly the way Base Camp sends them.
///
/// Recovered from Base Camp 1.9.10:
/// - `BaseCamp.UI.dll` (`EverestDataHelper.getChangeEffect` /
///   `getChangeBlockEffect`) fills an `EffData` / `BlockData` struct;
/// - `SDKDLL.dll` (`ChangeEffect`, `ChangeBlockEffect`, speed table at
///   `0x10005950`) normalises it and sends `14 2C` + the struct bytes.
///
/// Applying an effect is `SwitchProfile(profile, slot)` → the effect packet
/// → `SaveFlash(slot)`. Each effect lives in its own slot of the profile;
/// sending the packet without selecting the slot changes nothing visible
/// when another slot (e.g. custom mode) is active.
struct FirmwareLighting: Codable, Equatable {
    enum Effect: String, CaseIterable, Codable {
        case staticColor = "static"
        case wave
        case tornado
        case breathing
        case reactive
        case matrix
        case yeti
        case off

        /// Slot in the profile's effect menu (fixed by the firmware).
        var slot: UInt8 {
            switch self {
            case .staticColor: return 0
            case .wave: return 1
            case .tornado: return 2
            case .breathing: return 3
            case .reactive: return 4
            case .matrix: return 5
            case .yeti: return 7
            case .off: return 8
            }
        }

        /// Effect id (`byEffectIndex`).
        var id: UInt8 {
            switch self {
            case .staticColor: return 0x00
            case .breathing: return 0x01
            case .reactive: return 0x03
            case .wave: return 0x04
            case .yeti: return 0x06
            case .tornado: return 0x07
            case .matrix: return 0x09
            case .off: return 0x0C
            }
        }

        var modes: [ColorMode] {
            switch self {
            case .staticColor: return [.single]
            case .wave: return [.single, .dual, .quad, .rainbow]
            case .tornado: return [.single, .rainbow]
            case .breathing: return [.single, .dual, .rainbow]
            case .reactive, .matrix, .yeti: return [.withBackground]
            case .off: return []
            }
        }

        var hasSpeed: Bool { self != .staticColor && self != .off }
        var hasDirection: Bool { self == .wave || self == .tornado }
    }

    enum ColorMode: String, Codable {
        case single, dual, quad, rainbow
        /// Reactive / Matrix / Yeti: key colour + background colour.
        case withBackground
    }

    enum Direction: Int, Codable, CaseIterable {
        case right = 0, down = 2, left = 4, up = 6
    }

    var effect: Effect = .wave
    var mode: ColorMode = .rainbow
    var colors: [RGB] = [RGB(r: 255, g: 40, b: 120), RGB(r: 0, g: 180, b: 255),
                         RGB(r: 255, g: 200, b: 0), RGB(r: 120, g: 60, b: 255)]
    /// Base Camp's speed slider (0…100); the firmware only knows five steps.
    var speed: Double = 50
    var brightness: Double = 100
    var direction: Direction = .right
    var clockwise = true

    /// The colour mode actually used: falls back to the first supported one.
    var effectiveMode: ColorMode {
        let modes = effect.modes
        return modes.contains(mode) ? mode : (modes.first ?? .single)
    }

    func color(_ i: Int) -> RGB { i < colors.count ? colors[i] : RGB(r: 255, g: 255, b: 255) }

    /// 0…4, Base Camp's thresholds (≤12, ≤37, ≤62, ≤87, above).
    var speedLevel: Int {
        let s = Int(speed.rounded())
        switch s {
        case ...12: return 0
        case ...37: return 1
        case ...62: return 2
        case ...87: return 3
        default: return 4
        }
    }

    /// SDKDLL speed table: smaller = faster, one table per effect family.
    var hardwareSpeed: UInt8 {
        let level = speedLevel
        switch effect {
        case .wave, .tornado: return [10, 9, 8, 7, 6][level]
        case .breathing, .reactive: return [5, 4, 3, 1, 0][level]
        case .matrix: return [20, 15, 10, 5, 0][level]
        case .yeti: return [10, 7, 5, 3, 0][level]
        case .staticColor, .off: return 0xFF
        }
    }

    // MARK: - Packets

    /// `14 2C` + EffData / BlockData, byAll = 0.
    func packet() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 64)
        p[0] = 0x14; p[1] = 0x2C
        p[2] = effect.id
        p[3] = 0x00
        p[4] = hardwareSpeed
        p[5] = UInt8(max(0, min(100, brightness.rounded())))
        let c1 = color(0), c2 = color(1)

        func put(_ c: RGB, at i: Int) { p[i] = c.r; p[i + 1] = c.g; p[i + 2] = c.b }
        func stop(_ pos: UInt8, _ c: RGB, at i: Int) { p[i] = pos; put(c, at: i + 1) }

        switch effect {
        case .wave, .tornado:
            // BlockData: rand, dir, width, blockNum, then (pos,r,g,b) stops.
            p[7] = effect == .wave ? UInt8(direction.rawValue) : (clockwise ? 9 : 10)
            switch effectiveMode {
            case .rainbow:
                p[6] = 0x02; p[8] = 0x02; p[9] = 0x00
                p[10] = 0xFF; p[14] = 0xFF
            case .dual:
                // SDKDLL expands two colours into four stops: c1 c2 c1 c2.
                p[6] = 0x00; p[8] = 0x02; p[9] = 0x04
                stop(25, c1, at: 10); stop(50, c2, at: 14)
                stop(75, c1, at: 18); stop(100, c2, at: 22)
            case .quad:
                // The firmware's native four-stop wave (protocol §5.5.2).
                p[6] = 0x00; p[8] = 0x02; p[9] = 0x04
                stop(25, color(0), at: 10); stop(50, color(1), at: 14)
                stop(75, color(2), at: 18); stop(100, color(3), at: 22)
            default:
                p[6] = 0x00; p[8] = 0x00; p[9] = 0x01
                stop(100, c1, at: 10); p[14] = 0xFF
            }

        case .off:
            p[6] = 0xFF; p[7] = 0xFF; p[8] = 0xFF

        default:
            // EffData: rand, dir 0xFF, width 0xFF, colorLv[3], bkColor.
            p[7] = 0xFF; p[8] = 0xFF
            switch (effect, effectiveMode) {
            case (.breathing, .dual):
                p[6] = 0x10; put(c1, at: 9); put(c2, at: 12)
            case (.breathing, .rainbow):
                p[6] = 0x02
            case (_, .withBackground):
                p[6] = 0x00; put(c1, at: 9); put(c2, at: 18)
            default:
                p[6] = 0x00; put(c1, at: 9)
            }
        }
        return p
    }

    /// `14 00 00 00 <profile 1…5> <slot>` — SDKDLL SwitchProfile.
    static func switchProfile(_ profile: UInt8, slot: UInt8) -> [UInt8] {
        Proto.packet([0x14, 0x00, 0x00, 0x00, profile, slot])
    }

    /// `13 55 00 00 <slot>` — SDKDLL SaveFlash.
    static func saveFlash(slot: UInt8) -> [UInt8] {
        Proto.packet([0x13, 0x55, 0x00, 0x00, slot])
    }
}

extension Keyboard {
    /// Active profile (1…5) from the `11 00` firmware info reply
    /// (FWInfo.currentlyProfileIndex at byte 10).
    func currentProfile() -> UInt8 {
        transport.flush()
        try? transport.write(Proto.packet([0x11, 0x00]))
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            guard let r = transport.read(timeout: 0.3) else { break }
            if r[0] == 0x11, r[1] == 0x00, r.count > 10, (1...5).contains(r[10]) { return r[10] }
        }
        return 1
    }

    /// Apply a built-in effect the way Base Camp does. `save` commits the
    /// slot to flash so it survives a replug.
    func apply(_ lighting: FirmwareLighting, save: Bool = true, switchSlot: Bool = true) {
        let slot = lighting.effect.slot
        if switchSlot {
            let profile = currentProfile()
            send(FirmwareLighting.switchProfile(profile, slot: slot))
        }
        send(lighting.packet())
        if save { send(FirmwareLighting.saveFlash(slot: slot)) }
    }

    func send(_ packet: [UInt8], wait: TimeInterval = 0.25) {
        try? transport.write(packet)
        _ = transport.read(timeout: wait)
    }
}
