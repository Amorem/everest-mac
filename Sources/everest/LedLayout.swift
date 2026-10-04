import CoreGraphics
import Foundation

/// Physical geometry of the Everest Max (ISO UK), in key units: 1u is the
/// pitch of one key. Everything the app draws or animates is placed from
/// this table, so the preview, the effect math and the real board agree.
///
/// Colour indices (0…125) are the firmware's matrix ids, verified LED by LED
/// on the hardware. The side strips use their own 0…44 index space; Base Camp
/// calls them matrix ids 126…170 (side index = matrix id − 126).
enum LedLayout {
    enum Zone { case main, numpad, display }
    enum Shape { case rect, isoEnter }

    struct Key {
        let label: String
        /// Secondary legend printed above the main one (shifted symbol).
        let top: String?
        let index: Int?
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat
        var zone: Zone = .main
        var shape: Shape = .rect
        /// The aluminium Esc key with the Mountain logo.
        var special = false

        var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }

        /// Same key with another main legend and no shifted one.
        static func relabelled(_ k: Key, _ label: String) -> Key {
            var n = Key(label: label, top: nil, index: k.index, x: k.x, y: k.y, w: k.w, h: k.h)
            n.zone = k.zone; n.shape = k.shape; n.special = k.special
            return n
        }
    }

    static let mainLedCount = 152     // 8 packets × 19 slots (126 used)
    static let sideLedCount = 45      // 3 packets (19 + 19 + 7)

    // MARK: Board outline (units)

    /// Main board keys span x 0…18.25, rows 0…6.25.
    static let numpadOriginX: CGFloat = 19.35
    static let mainChassis = CGRect(x: -0.42, y: -0.45, width: 19.07, height: 7.1)
    static let numpadChassis = CGRect(x: 18.95, y: -0.45, width: 4.82, height: 7.1)
    /// The media dock clips onto the top edge, above F9…Pause.
    static let dock = CGRect(x: 10.4, y: -1.5, width: 8.2, height: 1.36)
    static let dialCenter = CGPoint(x: 18.05, y: -0.78)
    static let dialRadius: CGFloat = 1.02

    /// Drawing bounds of the whole set (chassis + dock + dial).
    static let bounds = CGRect(x: -0.5, y: -1.9, width: 24.4, height: 8.7)
    /// Bounds of the key field only — what effect coordinates are normalised to.
    static let keyField = CGRect(x: 0, y: 0, width: 23.35, height: 6.25)
    /// Width / height of the key field, for effects that need real distances.
    static var aspect: Double { Double(keyField.width / keyField.height) }

    // MARK: Keys

    /// All keys for a layout. The LED indices are the firmware's (`column × 9 +
    /// row`) and do not depend on the language; the shape does: ANSI boards
    /// have `\` (LED 119) at the end of the QWERTY row and a wide Enter, ISO
    /// boards the tall Enter, `#` (111) and the extra key beside Z (13).
    static func buildKeys(_ layout: KeyboardLayout) -> [Key] {
        let iso = layout.family == .iso
        var L: [Key] = []
        func put(_ label: String, _ idx: Int?, _ x: CGFloat, _ y: CGFloat,
                 _ w: CGFloat = 1, _ h: CGFloat = 1, top: String? = nil) {
            L.append(Key(label: label, top: top, index: idx, x: x, y: y, w: w, h: h))
        }

        // Row 0 — Esc, F-keys in groups of four, print cluster.
        L.append(Key(label: "", top: nil, index: 0, x: 0, y: 0, w: 1, h: 1, special: true))
        let fIdx = [9, 18, 27, 36, 45, 54, 63, 72, 81, 90, 99, 108]
        for i in 0..<12 {
            let group = CGFloat(i / 4)
            put("F\(i + 1)", fIdx[i], 2 + CGFloat(i) + group * 0.5, 0)
        }
        put("PRT SC", 117, 15.25, 0)
        put("SCR LK", 114, 16.25, 0)
        put("PAUSE", 123, 17.25, 0)

        // Row 1 — numbers. Two-symbol legends only where the keycap is known
        // (US, UK); other languages show Base Camp's single legend.
        let y1: CGFloat = 1.25
        put("`", 1, 0, y1, top: layout == .uk ? "¬" : "~")
        let nums = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        let shifted = layout == .uk ? ["!", "\"", "£", "$", "%", "^", "&", "*", "(", ")"]
                                    : ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"]
        for (i, idx) in [10, 19, 28, 37, 46, 55, 64, 73, 82, 91].enumerated() {
            put(nums[i], idx, 1 + CGFloat(i), y1, top: shifted[i])
        }
        put("-", 100, 11, y1, top: "_")
        put("=", 109, 12, y1, top: "+")
        put("⟵", 87, 13, y1, 2)
        put("INSERT", 96, 15.25, y1)
        put("HOME", 105, 16.25, y1)
        put("PG UP", 115, 17.25, y1)

        // Row 2 — QWERTY, ISO Enter starts here.
        let y2: CGFloat = 2.25
        put("TAB", 2, 0, y2, 1.5)
        for (i, idx) in [11, 20, 29, 38, 47, 56, 65, 74, 83, 92].enumerated() {
            put(["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"][i], idx, 1.5 + CGFloat(i), y2)
        }
        put("[", 101, 11.5, y2, top: "{")
        put("]", 110, 12.5, y2, top: "}")
        if iso {
            L.append(Key(label: "↵", top: nil, index: 120, x: 13.5, y: y2, w: 1.5, h: 2, shape: .isoEnter))
        } else {
            put("\\", 119, 13.5, y2, 1.5, top: "|")
        }
        put("DELETE", 88, 15.25, y2)
        put("END", 97, 16.25, y2)
        put("PG DN", 106, 17.25, y2)

        // Row 3 — home row; `#~` sits in the Enter notch.
        let y3: CGFloat = 3.25
        put("CAPS", 3, 0, y3, 1.75)
        let home = ["A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'"]
        let homeTop: [String?] = [nil, nil, nil, nil, nil, nil, nil, nil, nil, ":", layout == .uk ? "@" : "\""]
        for (i, idx) in [12, 21, 30, 39, 48, 57, 66, 75, 84, 93, 102].enumerated() {
            put(home[i], idx, 1.75 + CGFloat(i), y3, top: homeTop[i])
        }
        if iso {
            put("#", 111, 12.75, y3, top: "~")
        } else {
            L.append(Key(label: "ENTER", top: nil, index: 120, x: 12.75, y: y3, w: 2.25, h: 1))
        }

        // Row 4 — short ISO shift, `\|` key, arrows.
        let y4: CGFloat = 4.25
        if iso {
            put("SHIFT", 4, 0, y4, 1.25)
            put("\\", 13, 1.25, y4, top: "|")
        } else {
            put("SHIFT", 4, 0, y4, 2.25)
        }
        for (i, idx) in [22, 31, 40, 49, 58, 67, 76].enumerated() {
            put(["Z", "X", "C", "V", "B", "N", "M"][i], idx, 2.25 + CGFloat(i), y4)
        }
        put(",", 85, 9.25, y4, top: "<")
        put(".", 94, 10.25, y4, top: ">")
        put("/", 103, 11.25, y4, top: "?")
        put("SHIFT", 121, 12.25, y4, 2.75)
        put("▲", 124, 16.25, y4)

        // Row 5 — modifiers.
        let y5: CGFloat = 5.25
        put("CTRL", 5, 0, y5, 1.25)
        put("⊞", 14, 1.25, y5, 1.25)
        put("ALT", 23, 2.5, y5, 1.25)
        put("", 41, 3.75, y5, 6.25)
        put("ALT", 68, 10, y5, 1.25)
        put("⊞", 77, 11.25, y5, 1.25)
        put("FN", 86, 12.5, y5, 1.25)
        put("CTRL", 95, 13.75, y5, 1.25)
        put("◀", 104, 15.25, y5)
        put("▼", 113, 16.25, y5)
        put("▶", 122, 17.25, y5)

        // Numpad module with the four display keys on top.
        let nx = numpadOriginX
        func np(_ label: String, _ idx: Int?, _ x: CGFloat, _ y: CGFloat,
                _ w: CGFloat = 1, _ h: CGFloat = 1, top: String? = nil) {
            L.append(Key(label: label, top: top, index: idx, x: nx + x, y: y, w: w, h: h, zone: .numpad))
        }
        for i in 0..<4 {
            L.append(Key(label: "D\(i + 1)", top: nil, index: nil, x: nx + CGFloat(i), y: 0.05,
                         w: 1, h: 0.9, zone: .display))
        }
        np("NUM", 6, 0, y1, top: "LOCK")
        np("/", 24, 1, y1)
        np("*", 16, 2, y1)
        np("-", 15, 3, y1)
        np("7", 61, 0, y2, top: nil)
        np("8", 69, 1, y2)
        np("9", 70, 2, y2)
        np("+", 7, 3, y2, 1, 2)
        np("4", 51, 0, y3)
        np("5", 52, 1, y3)
        np("6", 60, 2, y3)
        np("1", 34, 0, y4)
        np("2", 42, 1, y4)
        np("3", 43, 2, y4)
        np("ENTER", 33, 3, y4, 1, 2)
        np("0", 78, 0, y5, 2)
        np(".", 79, 2, y5)
        return applyLegends(L, layout)
    }

    /// Replace the printing for languages other than US and UK with Base
    /// Camp's own table. Their two-symbol legends are not known, so those
    /// keys show one symbol, like in Base Camp.
    private static func applyLegends(_ keys: [Key], _ layout: KeyboardLayout) -> [Key] {
        guard layout != .us, layout != .uk else { return keys }
        let overrides = LayoutLegends.overrides[layout] ?? [:]
        return keys.map { k in
            guard k.zone == .main, !k.special, let i = k.index else { return k }
            var key = k
            if let label = overrides[i] { key = Key.relabelled(k, label) }
            else if k.top != nil { key = Key.relabelled(k, k.label) }   // drop the shifted symbol
            return key
        }
    }

    // MARK: Side strips (official map, Views/Everest/_Lighting)

    /// Side LED indices per edge, as Base Camp lists them (left→right,
    /// top→bottom).
    static let mainTop = [13, 14, 15, 7, 6, 5, 4, 3, 2, 1, 0]
    static let mainBottom = [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 12]
    static let mainLeft = [16, 17, 18, 19]
    static let mainRight = [9, 8, 10, 11]
    static let numpadTop = [44, 43, 42]
    static let numpadBottom = [35, 36, 37]
    static let numpadLeft = [31, 32, 33, 34]
    static let numpadRight = [41, 40, 39, 38]

    /// Clockwise rings from the top-left corner — used by chase effects.
    static let mainRing: [Int] = mainTop + mainRight + mainBottom.reversed() + mainLeft.reversed()
    static let numpadRing: [Int] = numpadTop + numpadRight + numpadBottom.reversed() + numpadLeft.reversed()

    /// Where each side LED sits, in key units, just outside the chassis edge.
    static let sidePoints: [CGPoint] = {
        var pts = [CGPoint](repeating: .zero, count: sideLedCount)
        func spread(_ leds: [Int], from a: CGPoint, to b: CGPoint) {
            for (i, led) in leds.enumerated() {
                let t = (CGFloat(i) + 0.5) / CGFloat(leds.count)
                pts[led] = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        let m = mainChassis, n = numpadChassis
        spread(mainTop, from: CGPoint(x: m.minX, y: m.minY), to: CGPoint(x: m.maxX, y: m.minY))
        spread(mainBottom, from: CGPoint(x: m.minX, y: m.maxY), to: CGPoint(x: m.maxX, y: m.maxY))
        spread(mainLeft, from: CGPoint(x: m.minX, y: m.minY), to: CGPoint(x: m.minX, y: m.maxY))
        spread(mainRight, from: CGPoint(x: m.maxX, y: m.minY), to: CGPoint(x: m.maxX, y: m.maxY))
        spread(numpadTop, from: CGPoint(x: n.minX, y: n.minY), to: CGPoint(x: n.maxX, y: n.minY))
        spread(numpadBottom, from: CGPoint(x: n.minX, y: n.maxY), to: CGPoint(x: n.maxX, y: n.maxY))
        spread(numpadLeft, from: CGPoint(x: n.minX, y: n.minY), to: CGPoint(x: n.minX, y: n.maxY))
        spread(numpadRight, from: CGPoint(x: n.maxX, y: n.minY), to: CGPoint(x: n.maxX, y: n.maxY))
        return pts
    }()

    // MARK: Derived tables

    /// Everything computed from the keys of one layout.
    final class Tables {
        let layout: KeyboardLayout
        let keys: [Key]
        let keyPositions: [Int: (x: Double, y: Double)]
        let positionTable: [(x: Double, y: Double)?]
        let usedIndices: [Int]
        let sideNeighbours: [[Int]]
        let columns: [[Int]]

        init(_ layout: KeyboardLayout) {
            self.layout = layout
            let keys = LedLayout.buildKeys(layout)
            self.keys = keys

            var pos: [Int: (x: Double, y: Double)] = [:]
            for key in keys {
                guard let idx = key.index else { continue }
                pos[idx] = LedLayout.normalise(key.center)
            }
            keyPositions = pos
            var table = [(x: Double, y: Double)?](repeating: nil, count: LedLayout.mainLedCount)
            for (i, p) in pos where i < LedLayout.mainLedCount { table[i] = p }
            positionTable = table
            usedIndices = (0..<LedLayout.mainLedCount).filter { table[$0] != nil }

            sideNeighbours = LedLayout.sidePoints.map { p in
                keys.compactMap { k -> (Int, CGFloat)? in
                    guard let i = k.index else { return nil }
                    let c = k.center
                    return (i, hypot(c.x - p.x, (c.y - p.y) * 1.4))
                }
                .sorted { $0.1 < $1.1 }
                .prefix(3)
                .map(\.0)
            }

            // Physical columns of keys (top→bottom), grouped by x.
            let items = keys.compactMap { k -> (idx: Int, x: CGFloat, y: CGFloat)? in
                guard let i = k.index else { return nil }
                return (i, k.center.x, k.center.y)
            }.sorted { $0.x < $1.x }
            var cols: [[(idx: Int, y: CGFloat)]] = []
            var currentX: CGFloat = -1000
            for it in items {
                if it.x - currentX > 0.5 {
                    cols.append([])
                    currentX = it.x
                }
                cols[cols.count - 1].append((it.idx, it.y))
            }
            columns = cols.map { $0.sorted { $0.y < $1.y }.map(\.idx) }
        }
    }

    /// The layout in use. Switching replaces the whole table set at once, so
    /// the renderer threads always see a consistent one.
    private static var tables = Tables(.uk)
    private static var cache: [KeyboardLayout: Tables] = [.uk: tables]

    static var layout: KeyboardLayout { tables.layout }

    static func use(_ layout: KeyboardLayout) {
        guard layout != tables.layout else { return }
        let t = cache[layout] ?? Tables(layout)
        cache[layout] = t
        tables = t
    }

    static var keys: [Key] { tables.keys }
    static var keyPositions: [Int: (x: Double, y: Double)] { tables.keyPositions }
    static var positionTable: [(x: Double, y: Double)?] { tables.positionTable }
    static var usedIndices: [Int] { tables.usedIndices }
    static var sideNeighbours: [[Int]] { tables.sideNeighbours }
    static var columns: [[Int]] { tables.columns }

    /// Normalised position of each side LED (may fall slightly outside 0…1).
    static let sidePositions: [(x: Double, y: Double)] = sidePoints.map { normalise($0) }

    static func normalise(_ p: CGPoint) -> (x: Double, y: Double) {
        (Double((p.x - keyField.minX) / keyField.width), Double((p.y - keyField.minY) / keyField.height))
    }
}
