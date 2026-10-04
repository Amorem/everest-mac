import XCTest
@testable import everest

final class LayoutTests: XCTestCase {
    override func tearDown() { LedLayout.use(.uk) }

    func testFirmwareCodes() {
        let table: [(Int, KeyboardLayout)] = [(4, .uk), (5, .french), (3, .german), (8, .italian), (11, .nordic),
                                              (15, .spanish), (12, .portuguese), (13, .hebrew), (22, .korean), (17, .us)]
        for (code, layout) in table { XCTAssertEqual(KeyboardLayout(firmwareCode: code), layout, "code \(code)") }
        XCTAssertEqual(KeyboardLayout(firmwareCode: 0), .us, "unknown codes fall back to US like Base Camp")
        XCTAssertEqual(KeyboardLayout(firmwareCode: 255), .us)
    }

    func testFamilies() {
        for l in [KeyboardLayout.us, .hebrew, .korean] { XCTAssertEqual(l.family, .ansi) }
        for l in [KeyboardLayout.uk, .french, .german, .italian, .nordic, .spanish, .portuguese] { XCTAssertEqual(l.family, .iso) }
    }

    func testKeySetsAndGeometry() {
        for layout in KeyboardLayout.allCases {
            LedLayout.use(layout)
            let keys = LedLayout.keys
            let indices = keys.compactMap(\.index)
            XCTAssertEqual(indices.count, Set(indices).count, "\(layout): LED indices are unique")
            XCTAssertTrue(indices.allSatisfy { $0 >= 0 && $0 < LedLayout.mainLedCount }, "\(layout): index range")
            let set = Set(indices)
            if layout.family == .iso {
                XCTAssertTrue(set.contains(13) && set.contains(111), "\(layout): ISO key and #")
                XCTAssertFalse(set.contains(119), "\(layout): no ANSI backslash")
                XCTAssertEqual(indices.count, 105, "\(layout): 105 keys")
            } else {
                XCTAssertTrue(set.contains(119), "\(layout): ANSI backslash")
                XCTAssertFalse(set.contains(13) || set.contains(111), "\(layout): no ISO keys")
                XCTAssertEqual(indices.count, 104, "\(layout): 104 keys")
            }
            XCTAssertTrue(set.isSuperset(of: [0, 120, 121, 41, 124, 33]), "\(layout): Esc, Enter, shifts, space, arrow, numpad Enter")
            XCTAssertEqual(keys.filter { $0.zone == .display }.count, 4, "\(layout): four display keys")
        }
    }

    func testKeysDoNotOverlap() {
        for layout in [KeyboardLayout.us, .uk] {
            LedLayout.use(layout)
            let keys = LedLayout.keys.filter { $0.zone != .display }
            for (i, a) in keys.enumerated() {
                for b in keys[(i + 1)...] {
                    let ra = CGRect(x: a.x, y: a.y, width: a.w, height: a.h).insetBy(dx: 0.05, dy: 0.05)
                    let rb = CGRect(x: b.x, y: b.y, width: b.w, height: b.h).insetBy(dx: 0.05, dy: 0.05)
                    // the ISO Enter is an L shape whose bounding box covers #
                    if a.shape == .isoEnter || b.shape == .isoEnter { continue }
                    XCTAssertFalse(ra.intersects(rb), "\(layout): '\(a.label)' overlaps '\(b.label)'")
                }
            }
        }
    }

    func testVerifiedUKPositions() {
        // Verified LED by LED on a UK-ISO board.
        LedLayout.use(.uk)
        func label(_ i: Int) -> String? { LedLayout.keys.first { $0.index == i }?.label }
        XCTAssertEqual(label(13), "\\")      // ISO key between left shift and Z
        XCTAssertEqual(label(111), "#")
        XCTAssertEqual(label(120), "↵")
        XCTAssertEqual(label(123), "PAUSE")
        XCTAssertEqual([104, 113, 122, 124].compactMap(label), ["◀", "▼", "▶", "▲"])
    }

    func testLegendOverridesLandOnRealKeys() {
        // Every override must name an LED that exists in that layout, so an
        // index error in Base Camp's tables cannot silently drop a legend.
        for (layout, overrides) in LayoutLegends.overrides {
            LedLayout.use(layout)
            let present = Set(LedLayout.keys.compactMap(\.index))
            for index in overrides.keys {
                XCTAssertTrue(present.contains(index), "\(layout): legend for LED \(index) has no key")
            }
        }
    }

    func testLegendsAreApplied() {
        LedLayout.use(.french)
        func label(_ i: Int) -> String? { LedLayout.keys.first { $0.index == i }?.label }
        XCTAssertEqual(label(11), "A")      // AZERTY: A where Q is on QWERTY
        XCTAssertEqual(label(12), "Q")
        XCTAssertEqual(label(13), "<")
        LedLayout.use(.german)
        XCTAssertEqual(LedLayout.keys.first { $0.index == 9 }?.label, "F1", "F1 is not relabelled by a mis-indexed table entry")
        XCTAssertEqual(LedLayout.keys.first { $0.index == 1 }?.label, "^")
        LedLayout.use(.korean)
        XCTAssertEqual(LedLayout.keys.first { $0.index == 11 }?.label, "ㅂ")
    }

    func testDerivedTables() {
        for layout in [KeyboardLayout.us, .uk] {
            LedLayout.use(layout)
            XCTAssertEqual(LedLayout.usedIndices.count, LedLayout.keys.compactMap(\.index).count)
            XCTAssertTrue(LedLayout.positionTable.enumerated().allSatisfy { ($0.element != nil) == LedLayout.usedIndices.contains($0.offset) })
            XCTAssertEqual(LedLayout.sideNeighbours.count, LedLayout.sideLedCount)
            XCTAssertTrue(LedLayout.sideNeighbours.allSatisfy { $0.count == 3 })
            XCTAssertEqual(LedLayout.columns.flatMap { $0 }.count, LedLayout.usedIndices.count)
        }
        // every side LED belongs to exactly one edge list
        let edges = LedLayout.mainTop + LedLayout.mainBottom + LedLayout.mainLeft + LedLayout.mainRight
            + LedLayout.numpadTop + LedLayout.numpadBottom + LedLayout.numpadLeft + LedLayout.numpadRight
        XCTAssertEqual(Set(edges), Set(0..<LedLayout.sideLedCount))
        XCTAssertEqual(edges.count, LedLayout.sideLedCount)
    }
}
