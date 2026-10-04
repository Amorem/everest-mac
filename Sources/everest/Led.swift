import Foundation

// MARK: - Colour

struct RGB: Equatable, Hashable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 255, g: 255, b: 255)

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    var hex: String { String(format: "%02x%02x%02x", r, g, b) }

    // Stored as "rrggbb" in the config file.
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = RGB(hex: s) ?? .white
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    var luminance: Double { (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255 }

    /// Blend in linear light so red→green does not pass through a dirty
    /// yellow the way a naive sRGB lerp does.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let t = max(0, min(1, t))
        return RGB(r: srgb(lin(a.r) + (lin(b.r) - lin(a.r)) * t),
                   g: srgb(lin(a.g) + (lin(b.g) - lin(a.g)) * t),
                   b: srgb(lin(a.b) + (lin(b.b) - lin(a.b)) * t))
    }

    /// Scale intensity in linear light (a 50 % level looks half as bright).
    static func scale(_ c: RGB, _ f: Double) -> RGB {
        let f = max(0, min(1, f))
        return RGB(r: srgb(lin(c.r) * f), g: srgb(lin(c.g) * f), b: srgb(lin(c.b) * f))
    }

    /// Additive blend (both in linear light), clipped.
    static func add(_ a: RGB, _ b: RGB) -> RGB {
        RGB(r: srgb(lin(a.r) + lin(b.r)), g: srgb(lin(a.g) + lin(b.g)), b: srgb(lin(a.b) + lin(b.b)))
    }

    static func hsv(_ h: Double, _ s: Double = 1, _ v: Double = 1) -> RGB {
        var h = h.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return RGB(r: UInt8(r * 255), g: UInt8(g * 255), b: UInt8(b * 255))
    }

    private static let linTable: [Double] = (0...255).map { pow(Double($0) / 255.0, 2.2) }
    @inline(__always) private static func lin(_ v: UInt8) -> Double { linTable[Int(v)] }
    @inline(__always) private static func srgb(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, pow(max(0, min(1, v)), 1 / 2.2) * 255 + 0.5)))
    }
}

// MARK: - Mac-rendered effects

/// An effect rendered on the Mac and streamed to the keyboard through the
/// custom-mode packets: exact colours, any number of them, any pattern.
struct LedEffect: Codable, Equatable {
    enum Kind: String, CaseIterable, Codable {
        case solid, gradient, rainbow, wave, breathe, aurora, plasma, vortex
        case ripple, fire, rain, starlight, scanner, equalizer, off
    }

    var kind: Kind = .aurora
    var palette: [RGB] = [RGB(r: 0, g: 255, b: 170), RGB(r: 0, g: 140, b: 255), RGB(r: 170, g: 60, b: 255)]
    var speed: Double = 50           // 1…100, 50 = nominal
    var brightness: Double = 100     // 0…100
    var direction: Int = 0           // 0 →, 2 ↓, 4 ←, 6 ↑, 8 from the centre
    var perKey: [Int: RGB] = [:]     // .solid: keys painted in the editor

    var usesDirection: Bool {
        switch kind {
        case .gradient, .rainbow, .wave, .scanner: return true
        default: return false
        }
    }

    var usesSpeed: Bool { kind != .solid && kind != .off }
    var usesPalette: Bool { kind != .rainbow && kind != .fire && kind != .off }
}

// MARK: - Renderer

/// Renders both the Mac effects and a simulation of the firmware effects
/// (for previews) onto the real layout.
enum LedRenderer {
    typealias Frame = (main: [RGB], side: [RGB])

    static func render(_ effect: LedEffect, time: Double) -> Frame {
        var main = [RGB](repeating: .black, count: LedLayout.mainLedCount)
        let pal = Palette(effect.palette)
        let t = time * pow(2, (effect.speed - 50) / 25)
        let bright = max(0, min(1, effect.brightness / 100))
        let A = LedLayout.aspect

        func axis(_ p: (x: Double, y: Double)) -> Double {
            switch effect.direction {
            case 2: return p.y * 0.6
            case 4: return 1 - p.x
            case 6: return (1 - p.y) * 0.6
            case 8: return hypot((p.x - 0.5) * A, p.y - 0.5) / (A * 0.5)
            default: return p.x
            }
        }

        for i in 0..<LedLayout.mainLedCount {
            guard let p = LedLayout.positionTable[i] else { continue }
            var c = RGB.black
            switch effect.kind {
            case .off:
                break
            case .solid:
                c = effect.perKey.isEmpty ? pal[0] : (effect.perKey[i] ?? .black)
            case .gradient:
                c = pal.smooth(axis(p) * 0.85 - t * 0.12)
            case .rainbow:
                c = RGB.hsv(axis(p) * 0.9 - t * 0.18)
            case .wave:
                let a = axis(p)
                let v = 0.5 + 0.5 * sin(2 * .pi * (a * 1.4 - t * 0.45))
                c = RGB.scale(pal.smooth(a * 0.4 - t * 0.06), 0.16 + 0.84 * pow(v, 1.6))
            case .breathe:
                c = breathe(pal, t)
            case .aurora:
                let n1 = Noise.fbm(p.x * A * 0.55 + t * 0.07, p.y * 1.1 - t * 0.05, t * 0.11)
                let n2 = Noise.fbm(p.x * A * 0.35 - t * 0.04 + 7.3, p.y * 0.9, t * 0.17 + 3.1)
                let curtain = smoothstep(0.26, 0.68, n2)
                c = RGB.scale(pal.smooth(n1 * 1.6 + t * 0.03), 0.34 + 0.66 * curtain)
            case .plasma:
                let x = p.x * A, y = p.y
                let v = sin(x * 1.3 + t * 0.9) + sin(y * 4.0 - t * 0.7)
                    + sin((x * 0.8 + y * 2.0) + t * 0.6) + sin(hypot(x - A / 2, y - 0.5) * 3.0 - t * 1.1)
                c = pal.smooth(v / 8 + 0.5 + t * 0.02)
            case .vortex:
                let dx = (p.x - 0.5) * A, dy = p.y - 0.5
                let ang = atan2(dy, dx) / (2 * .pi)
                let r = hypot(dx, dy)
                c = pal.smooth(ang + r * 0.35 - t * 0.22)
            case .ripple:
                c = ripple(pal, p, t, A)
            case .fire:
                c = fire(pal, p, t, A)
            case .starlight:
                c = starlight(pal, i, t)
            case .scanner:
                c = scanner(pal, axis(p), t)
            case .rain, .equalizer:
                break
            }
            main[i] = c
        }

        if effect.kind == .rain { rain(pal, t, &main) }
        if effect.kind == .equalizer { equalizer(pal, t, &main) }

        // Side strips: sample the same field where it is continuous, follow
        // the neighbouring keys for particle effects.
        var side = [RGB](repeating: .black, count: LedLayout.sideLedCount)
        for s in 0..<LedLayout.sideLedCount {
            let p = LedLayout.sidePositions[s]
            switch effect.kind {
            case .off: break
            case .solid:
                side[s] = effect.perKey.isEmpty ? pal[0] : average(LedLayout.sideNeighbours[s].map { main[$0] })
            case .gradient: side[s] = pal.smooth(axis(p) * 0.85 - t * 0.12)
            case .rainbow: side[s] = RGB.hsv(axis(p) * 0.9 - t * 0.18)
            case .breathe: side[s] = breathe(pal, t)
            default: side[s] = average(LedLayout.sideNeighbours[s].map { main[$0] })
            }
        }

        if bright < 0.999 {
            for i in main.indices { main[i] = RGB.scale(main[i], bright) }
            for i in side.indices { side[i] = RGB.scale(side[i], bright) }
        }
        return (main, side)
    }

    // MARK: Effect bodies

    private static func breathe(_ pal: Palette, _ t: Double) -> RGB {
        // One full breath per palette entry, eased in and out.
        let phase = t * 0.22
        let k = Int(floor(phase))
        let f = phase - Double(k)
        let level = pow(sin(.pi * f), 2)
        return RGB.scale(pal[((k % pal.count) + pal.count) % pal.count], 0.04 + 0.96 * level)
    }

    private static func ripple(_ pal: Palette, _ p: (x: Double, y: Double), _ t: Double, _ A: Double) -> RGB {
        // Drops land on random keys; each sends one ring outward.
        var acc = RGB.black
        let period = 0.9
        let now = t / period
        for k in 0..<4 {
            let n = Int(floor(now)) - k
            let age = (now - Double(n)) * period
            let seed = Noise.hash(n * 7 + 3)
            let cx = (0.08 + 0.84 * Noise.hash(n * 13 + 1)) * A
            let cy = 0.15 + 0.7 * Noise.hash(n * 29 + 5)
            let d = hypot(p.x * A - cx, p.y - cy)
            let radius = age * 1.35
            let ring = exp(-pow((d - radius) / 0.22, 2))
            let fade = max(0, 1 - age / 3.2)
            if ring * fade > 0.01 {
                acc = RGB.add(acc, RGB.scale(pal.smooth(seed), ring * fade))
            }
        }
        return RGB.add(RGB.scale(pal[0], 0.035), acc)
    }

    private static func fire(_ pal: Palette, _ p: (x: Double, y: Double), _ t: Double, _ A: Double) -> RGB {
        // Heat rises from the bottom row; the palette is the heat ramp.
        let n = Noise.fbm(p.x * A * 1.1, p.y * 2.6 + t * 1.8, t * 0.4)
        let base = pow(p.y, 1.4)
        let heat = max(0, min(1, base * 1.15 - 0.22 + (n - 0.5) * 1.15))
        let ramp = fireRamp
        let x = heat * Double(ramp.count - 1)
        let i = min(ramp.count - 2, Int(x))
        return RGB.mix(ramp[i], ramp[i + 1], x - Double(i))
    }

    /// Black body: ember → red → orange → yellow → white-hot.
    private static let fireRamp: [RGB] = ["000000", "5a0000", "e01b00", "ff7a00", "ffc23a", "fff1c4"]
        .compactMap { RGB(hex: $0) }

    private static func starlight(_ pal: Palette, _ i: Int, _ t: Double) -> RGB {
        let seed = Noise.hash(i * 31 + 7)
        let period = 2.4 + seed * 4.0
        let phase = t / period + seed * 13
        let cycle = Int(floor(phase))
        let f = phase - Double(cycle)
        let level = f < 0.3 ? pow(sin(.pi * f / 0.3), 2) : 0
        let colour = pal.pick(Noise.hash(i * 17 + cycle * 101))
        return RGB.add(RGB.scale(pal[0], 0.015), RGB.scale(colour, level))
    }

    private static func scanner(_ pal: Palette, _ a: Double, _ t: Double) -> RGB {
        let s = t * 0.45
        let pass = Int(floor(s))
        let f = s - Double(pass)
        let forward = pass % 2 == 0
        let pos = -0.1 + 1.2 * (forward ? f : 1 - f)
        let d = forward ? pos - a : a - pos
        let head = exp(-pow(d / 0.035, 2))
        let tail = d > 0 ? exp(-d / 0.16) * 0.6 : 0
        return RGB.scale(pal[((pass % pal.count) + pal.count) % pal.count], max(head, tail))
    }

    private static func rain(_ pal: Palette, _ t: Double, _ main: inout [RGB]) {
        for i in main.indices where LedLayout.positionTable[i] != nil {
            main[i] = RGB.scale(pal[0], 0.012)
        }
        for (ci, column) in LedLayout.columns.enumerated() {
            let seed = Noise.hash(ci * 977 + 11)
            let speed = 3.2 + seed * 3.5                      // rows per second
            let gap = 0.8 + Noise.hash(ci * 31) * 2.4
            let span = Double(column.count) + 4
            let period = span / speed + gap
            let local = (t + seed * period).truncatingRemainder(dividingBy: period)
            let head = local * speed - 1
            let colour = pal.pick(Noise.hash(ci * 59 + Int(floor((t + seed * period) / period)) * 7))
            for (r, idx) in column.enumerated() {
                let d = head - Double(r)
                var level = 0.0
                if d >= 0 { level = exp(-d * 0.9) } else if d > -1 { level = 1 + d }
                guard level > 0.02 else { continue }
                let c = d < 0.6 && d > -1 ? RGB.mix(colour, .white, 0.45 * level) : colour
                main[idx] = RGB.add(main[idx], RGB.scale(c, level))
            }
        }
    }

    private static func equalizer(_ pal: Palette, _ t: Double, _ main: inout [RGB]) {
        for (ci, column) in LedLayout.columns.enumerated() {
            let x = Double(ci) * 0.37
            let level = max(0.05, min(1, 0.15 + Noise.fbm(x, t * 0.9, 1.7) * 1.25 - 0.25))
            let rows = Double(column.count)
            for (r, idx) in column.enumerated() {
                let fromBottom = rows - Double(r)                  // 1 … rows
                let lit = level * rows - (fromBottom - 1)
                let height = (fromBottom - 1) / max(1, rows - 1)
                let colour = pal.smooth(height * 0.75)
                main[idx] = RGB.scale(colour, max(0.04, min(1, lit)))
            }
        }
    }

    private static func average(_ cs: [RGB]) -> RGB {
        guard !cs.isEmpty else { return .black }
        var r = 0.0, g = 0.0, b = 0.0
        for c in cs { r += Double(c.r); g += Double(c.g); b += Double(c.b) }
        let n = Double(cs.count)
        return RGB(r: UInt8(r / n), g: UInt8(g / n), b: UInt8(b / n))
    }

    @inline(__always) static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Firmware simulation

    /// What the keyboard's own engine roughly looks like — for previews only;
    /// the real effect runs in the firmware.
    static func render(_ fw: FirmwareLighting, time: Double) -> Frame {
        var main = [RGB](repeating: .black, count: LedLayout.mainLedCount)
        var side = [RGB](repeating: .black, count: LedLayout.sideLedCount)
        let rate = [0.35, 0.55, 0.8, 1.15, 1.6][fw.speedLevel]
        let t = time * rate
        let mode = fw.effectiveMode
        let c1 = fw.color(0), c2 = fw.color(1)
        let A = LedLayout.aspect
        let stops: [RGB] = {
            switch mode {
            case .dual: return [c1, c2]
            case .quad: return Array(fw.colors.prefix(4))
            default: return [c1]
            }
        }()
        let pal = Palette(stops)

        func field(_ p: (x: Double, y: Double)) -> RGB {
            switch fw.effect {
            case .off:
                return .black
            case .staticColor:
                return c1
            case .breathing:
                let phase = t * 0.5
                let k = Int(floor(phase))
                let level = pow(sin(.pi * (phase - Double(k))), 2)
                let colour: RGB
                switch mode {
                case .rainbow: colour = RGB.hsv(Double(k) * 0.13)
                case .dual: colour = k % 2 == 0 ? c1 : c2
                default: colour = c1
                }
                return RGB.scale(colour, level)
            case .wave:
                let a: Double
                switch fw.direction {
                case .right: a = p.x
                case .left: a = 1 - p.x
                case .down: a = p.y * 0.5
                case .up: a = (1 - p.y) * 0.5
                }
                switch mode {
                case .rainbow: return RGB.hsv(a - t * 0.35)
                case .dual, .quad: return pal.smooth(a * 1.0 - t * 0.35)
                default:
                    let v = 0.5 + 0.5 * sin(2 * .pi * (a - t * 0.35))
                    return RGB.scale(c1, pow(v, 1.6))
                }
            case .tornado:
                let dx = (p.x - 0.5) * A, dy = p.y - 0.5
                var ang = atan2(dy, dx) / (2 * .pi)
                if !fw.clockwise { ang = -ang }
                let u = ang - t * 0.3
                if mode == .rainbow { return RGB.hsv(u) }
                let v = u - floor(u)
                return RGB.scale(c1, pow(v, 1.4))
            case .reactive, .matrix, .yeti:
                return c2
            }
        }

        for i in 0..<LedLayout.mainLedCount {
            guard let p = LedLayout.positionTable[i] else { continue }
            main[i] = field(p)
        }

        switch fw.effect {
        case .reactive:
            // Simulated key presses fading back to the background colour.
            for k in 0..<6 {
                let phase = t * 1.4 + Double(k) / 6
                let n = Int(floor(phase))
                let f = phase - Double(n)
                let idx = keyIndex(Noise.hash(n * 37 + k * 101))
                main[idx] = RGB.mix(c2, c1, pow(1 - f, 1.5))
            }
        case .yeti:
            for i in 0..<LedLayout.mainLedCount {
                guard let p = LedLayout.positionTable[i] else { continue }
                var level = 0.0
                for k in 0..<3 {
                    let phase = t * 0.6 + Double(k) / 3
                    let n = Int(floor(phase))
                    let age = phase - Double(n)
                    let cx = (0.1 + 0.8 * Noise.hash(n * 11 + k * 3)) * A
                    let cy = 0.2 + 0.6 * Noise.hash(n * 23 + k * 7)
                    let d = hypot(p.x * A - cx, p.y - cy)
                    level = max(level, exp(-pow((d - age * 2.4) / 0.25, 2)) * (1 - age))
                }
                main[i] = RGB.mix(c2, c1, level)
            }
        case .matrix:
            for (ci, column) in LedLayout.columns.enumerated() {
                let seed = Noise.hash(ci * 131 + 9)
                let span = Double(column.count) + 3
                let head = ((t * 2.2 + seed * 8).truncatingRemainder(dividingBy: span + 2)) - 1
                for (r, idx) in column.enumerated() {
                    let d = head - Double(r)
                    let level = d >= 0 ? exp(-d * 1.1) : 0
                    main[idx] = RGB.mix(c2, c1, level)
                }
            }
        default:
            break
        }

        for s in 0..<LedLayout.sideLedCount {
            switch fw.effect {
            case .reactive, .matrix, .yeti: side[s] = c2
            default: side[s] = field(LedLayout.sidePositions[s])
            }
        }
        let bright = max(0, min(1, fw.brightness / 100))
        if bright < 0.999 {
            for i in main.indices { main[i] = RGB.scale(main[i], bright) }
            for i in side.indices { side[i] = RGB.scale(side[i], bright) }
        }
        return (main, side)
    }

    private static var usedIndices: [Int] { LedLayout.usedIndices }
    private static func keyIndex(_ u: Double) -> Int {
        usedIndices[min(usedIndices.count - 1, Int(u * Double(usedIndices.count)))]
    }
}

/// A cyclic colour palette sampled smoothly in linear light.
struct Palette {
    let colors: [RGB]
    init(_ colors: [RGB]) { self.colors = colors.isEmpty ? [.white] : colors }
    var count: Int { colors.count }
    subscript(i: Int) -> RGB { colors[((i % colors.count) + colors.count) % colors.count] }

    /// t in palette periods: 0 → first colour, 1 → back to the first.
    func smooth(_ t: Double) -> RGB {
        guard colors.count > 1 else { return colors[0] }
        var x = t.truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }
        let s = x * Double(colors.count)
        let i = Int(s) % colors.count
        let f = s - Double(Int(s))
        let e = f * f * (3 - 2 * f)
        return RGB.mix(colors[i], colors[(i + 1) % colors.count], e)
    }

    func pick(_ u: Double) -> RGB { colors[min(colors.count - 1, Int(u * Double(colors.count)))] }
}

/// Small deterministic value noise — organic motion without randomness that
/// changes between frames.
enum Noise {
    @inline(__always) static func hash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &* 0x9E3779B97F4A7C15
        x ^= x >> 31; x &*= 0xBF58476D1CE4E5B9; x ^= x >> 29
        return Double(x % 100_000) / 100_000
    }

    @inline(__always) private static func h3(_ x: Int, _ y: Int, _ z: Int) -> Double {
        hash(x &* 73856093 ^ y &* 19349663 ^ z &* 83492791)
    }

    static func value(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y)), zi = Int(floor(z))
        let xf = x - Double(xi), yf = y - Double(yi), zf = z - Double(zi)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf), w = zf * zf * (3 - 2 * zf)
        func l(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let x00 = l(h3(xi, yi, zi), h3(xi + 1, yi, zi), u)
        let x10 = l(h3(xi, yi + 1, zi), h3(xi + 1, yi + 1, zi), u)
        let x01 = l(h3(xi, yi, zi + 1), h3(xi + 1, yi, zi + 1), u)
        let x11 = l(h3(xi, yi + 1, zi + 1), h3(xi + 1, yi + 1, zi + 1), u)
        return l(l(x00, x10, v), l(x01, x11, v), w)
    }

    static func fbm(_ x: Double, _ y: Double, _ z: Double) -> Double {
        (value(x, y, z) * 0.62 + value(x * 2.03, y * 2.03, z * 1.7 + 5.2) * 0.38)
    }
}

// MARK: - Player

/// Streams Mac-rendered frames to the keyboard.
///
/// The HID session is opened *on the player thread*: IOKit delivers the
/// keyboard's acknowledgements to the run loop of the thread that opened the
/// device, and the player waits for each ack (flow control). Opening it
/// elsewhere made every wait time out — 11 × 20 ms per frame, ~4 fps.
final class LedPlayer {
    private var running = false
    private var thread: Thread?
    private var effect: LedEffect
    private let lock = NSLock()
    private(set) var lastFrame: LedRenderer.Frame = (
        [RGB](repeating: .black, count: LedLayout.mainLedCount),
        [RGB](repeating: .black, count: LedLayout.sideLedCount))
    /// Called when the keyboard goes away (false) or comes back (true).
    var onConnection: ((Bool) -> Void)?

    init(effect: LedEffect) {
        self.effect = effect
    }

    func snapshot() -> LedRenderer.Frame {
        lock.lock(); defer { lock.unlock() }
        return lastFrame
    }

    func update(_ effect: LedEffect) {
        lock.lock(); self.effect = effect; lock.unlock()
    }

    private var currentEffect: LedEffect {
        lock.lock(); defer { lock.unlock() }
        return effect
    }

    func start(fps: Double = 30) {
        guard !running else { return }
        running = true
        thread = Thread { [weak self] in
            guard let self else { return }
            let interval = 1.0 / max(1, min(60, fps))
            let t0 = Date()
            let stats = ProcessInfo.processInfo.environment["EVEREST_LED_STATS"] != nil
            var frames = 0
            var statsStart = Date()
            var announced = false
            var connectedOnce = false
            // One pass per connection: if the keyboard is unplugged the
            // writes fail, the session is dropped and reopened when it is back.
            while self.running {
                guard let kb = try? Keyboard() else {
                    if !announced { self.onConnection?(false); announced = true }
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                if announced || !connectedOnce { self.onConnection?(true) }
                connectedOnce = true
                announced = false
                kb.wake()
                let stream = FrameStream(keyboard: kb)
                stream.prepare()
                var failures = 0
                while self.running && failures < 5 {
                    // A picture upload owns the channel for a while.
                    if FlashBusy.active { Thread.sleep(forTimeInterval: 0.3); continue }
                    let frameStart = Date()
                    let frame = LedRenderer.render(self.currentEffect, time: frameStart.timeIntervalSince(t0))
                    self.lock.lock(); self.lastFrame = frame; self.lock.unlock()
                    failures = stream.push(frame) ? 0 : failures + 1
                    if stats {
                        frames += 1
                        let dt = Date().timeIntervalSince(statsStart)
                        if dt >= 2 {
                            stderr(String(format: "led: %.1f fps", Double(frames) / dt))
                            frames = 0
                            statsStart = Date()
                        }
                    }
                    let spent = Date().timeIntervalSince(frameStart)
                    if spent < interval { Thread.sleep(forTimeInterval: interval - spent) }
                }
                kb.close()
                if self.running { Thread.sleep(forTimeInterval: 1) }
            }
        }
        thread?.name = "everest.led"
        thread?.start()
    }

    func stop() {
        running = false
        thread = nil
    }

    /// Enter custom mode and push one frame (no animation), on the caller's
    /// session — used to show and save a static design.
    static func applyOnce(_ effect: LedEffect, keyboard kb: Keyboard) {
        let stream = FrameStream(keyboard: kb)
        stream.prepare()
        stream.push(LedRenderer.render(effect, time: 0))
    }
}

/// The custom-mode packet stream (§5.11), sending only what changed.
final class FrameStream {
    private let kb: Keyboard
    private var sent: [[UInt8]] = []
    private var bound = false

    init(keyboard: Keyboard) { kb = keyboard }

    /// `SwitchProfile(profile, 6)` + `SwitchToCustomizeEffect(100)` — the
    /// Windows service's order. Brightness is applied when rendering.
    func prepare() {
        let profile = kb.currentProfile()
        kb.send(FirmwareLighting.switchProfile(profile, slot: 6), wait: 0.3)
        usleep(120_000)
        kb.send(Proto.packet([0x14, 0x2C, 0x0A, 0x00, 0xFF, 100, 0x00]), wait: 0.3)
        usleep(120_000)
        sent = []
        bound = false
    }

    /// Sends what changed; false when a write failed (device gone).
    @discardableResult
    func push(_ frame: LedRenderer.Frame) -> Bool {
        var ok = true
        var packets: [[UInt8]] = []
        for ix in 0..<8 {
            var p = [UInt8](repeating: 0, count: 64)
            p[0] = 0x14; p[1] = 0x2C; p[2] = 0x00; p[3] = 0x01
            p[4] = UInt8(ix); p[5] = 100
            for i in 0..<19 {
                let c = frame.main[ix * 19 + i]
                p[7 + i * 3] = c.r; p[8 + i * 3] = c.g; p[9 + i * 3] = c.b
            }
            packets.append(p)
        }
        for (ix, count) in [19, 19, 7].enumerated() {
            var p = [UInt8](repeating: 0, count: 64)
            p[0] = 0x14; p[1] = 0x2D; p[2] = 0x0A
            p[4] = UInt8(ix); p[5] = 0xFF
            for i in 0..<count {
                let c = frame.side[ix * 19 + i]
                p[7 + i * 3] = c.r; p[8 + i * 3] = c.g; p[9 + i * 3] = c.b
            }
            packets.append(p)
        }
        for (n, p) in packets.enumerated() where sent.count != packets.count || sent[n] != p {
            do {
                try kb.transport.write(p)
            } catch {
                ok = false
            }
            _ = kb.transport.read(timeout: 0.03)
        }
        sent = ok ? packets : []   // resend everything after a failure
        if !bound {
            bound = true
            // Colours first, then bind every key to the static slot (§5.11.5).
            for chunk in 0..<3 {
                kb.send(Proto.packet([0x14, 0xA0, UInt8(chunk), 0x01]), wait: 0.1)
            }
        }
        return ok
    }
}
