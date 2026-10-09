import XCTest
@testable import everest

/// Byte-exact checks of what is sent to the keyboard. The expected bytes come
/// from Base Camp's SDK (disassembly) and from packets verified on hardware,
/// so a refactor that changes one of them fails here before it reaches a
/// keyboard.
final class ProtocolTests: XCTestCase {
    private func hex(_ p: [UInt8], _ n: Int = 26) -> String {
        p.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func fw(_ effect: FirmwareLighting.Effect, _ mode: FirmwareLighting.ColorMode = .single) -> FirmwareLighting {
        var l = FirmwareLighting()
        l.effect = effect
        l.mode = mode
        l.speed = 50          // level 3 of 5
        l.brightness = 80     // 0x50
        l.colors = [RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 0, b: 255), RGB(r: 255, g: 255, b: 255)]
        return l
    }

    // MARK: Built-in lighting

    func testStaticAndOff() {
        XCTAssertEqual(hex(fw(.staticColor).packet()), "14 2c 00 00 ff 50 00 ff ff ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(hex(fw(.off).packet(), 9), "14 2c 0c 00 ff 50 ff ff ff")
    }

    func testBreathing() {
        XCTAssertEqual(hex(fw(.breathing).packet(), 12), "14 2c 01 00 03 50 00 ff ff ff 00 00")
        XCTAssertEqual(hex(fw(.breathing, .rainbow).packet(), 9), "14 2c 01 00 03 50 02 ff ff")
        XCTAssertEqual(hex(fw(.breathing, .dual).packet(), 15), "14 2c 01 00 03 50 10 ff ff ff 00 00 00 ff 00")
    }

    func testWave() {
        XCTAssertEqual(hex(fw(.wave).packet(), 15), "14 2c 04 00 08 50 00 00 00 01 64 ff 00 00 ff")
        XCTAssertEqual(hex(fw(.wave, .rainbow).packet(), 15), "14 2c 04 00 08 50 02 00 02 00 ff 00 00 00 ff")
        // Two colours are sent as four gradient stops: c1 c2 c1 c2.
        XCTAssertEqual(hex(fw(.wave, .dual).packet()),
                       "14 2c 04 00 08 50 00 00 02 04 19 ff 00 00 32 00 ff 00 4b ff 00 00 64 00 ff 00")
        XCTAssertEqual(hex(fw(.wave, .quad).packet()),
                       "14 2c 04 00 08 50 00 00 02 04 19 ff 00 00 32 00 ff 00 4b 00 00 ff 64 ff ff ff")
    }

    func testWaveDirections() {
        for (dir, byte) in [(FirmwareLighting.Direction.right, 0), (.down, 2), (.left, 4), (.up, 6)] {
            var l = fw(.wave); l.direction = dir
            XCTAssertEqual(Int(l.packet()[7]), byte)
        }
    }

    func testTornado() {
        XCTAssertEqual(hex(fw(.tornado).packet(), 15), "14 2c 07 00 08 50 00 09 00 01 64 ff 00 00 ff")
        var ccw = fw(.tornado); ccw.clockwise = false
        XCTAssertEqual(ccw.packet()[7], 10)
        XCTAssertEqual(hex(fw(.tornado, .rainbow).packet(), 15), "14 2c 07 00 08 50 02 09 02 00 ff 00 00 00 ff")
    }

    func testTwoColourEffects() {
        // key colour at 9…11, background colour at 18…20
        let reactive = fw(.reactive, .withBackground).packet()
        XCTAssertEqual(reactive[2], 0x03)
        XCTAssertEqual(Array(reactive[9...11]), [255, 0, 0])
        XCTAssertEqual(Array(reactive[18...20]), [0, 255, 0])
        XCTAssertEqual(fw(.yeti, .withBackground).packet()[2], 0x06)
        XCTAssertEqual(fw(.matrix, .withBackground).packet()[2], 0x09)
    }

    func testSpeedSteps() {
        var l = fw(.wave)
        let expected: [(Double, Int)] = [(0, 0), (12, 0), (13, 1), (37, 1), (38, 2), (62, 2), (63, 3), (87, 3), (88, 4), (100, 4)]
        for (speed, level) in expected {
            l.speed = speed
            XCTAssertEqual(l.speedLevel, level, "speed \(speed)")
        }
        // Per-effect hardware tables (smaller = faster).
        func hw(_ e: FirmwareLighting.Effect, _ level: Int) -> UInt8 {
            var x = fw(e); x.speed = [0, 25, 50, 75, 100][level]; return x.hardwareSpeed
        }
        XCTAssertEqual((0..<5).map { hw(.wave, $0) }, [10, 9, 8, 7, 6])
        XCTAssertEqual((0..<5).map { hw(.breathing, $0) }, [5, 4, 3, 1, 0])
        XCTAssertEqual((0..<5).map { hw(.matrix, $0) }, [20, 15, 10, 5, 0])
        XCTAssertEqual((0..<5).map { hw(.yeti, $0) }, [10, 7, 5, 3, 0])
        XCTAssertEqual(hw(.staticColor, 2), 0xFF)
    }

    func testEffectSlotsAndIds() {
        let slots = FirmwareLighting.Effect.allCases.map { ($0, $0.slot) }
        XCTAssertEqual(slots.first { $0.0 == .staticColor }?.1, 0)
        XCTAssertEqual(slots.first { $0.0 == .wave }?.1, 1)
        XCTAssertEqual(slots.first { $0.0 == .tornado }?.1, 2)
        XCTAssertEqual(slots.first { $0.0 == .breathing }?.1, 3)
        XCTAssertEqual(slots.first { $0.0 == .reactive }?.1, 4)
        XCTAssertEqual(slots.first { $0.0 == .matrix }?.1, 5)
        XCTAssertEqual(slots.first { $0.0 == .yeti }?.1, 7)
        XCTAssertEqual(slots.first { $0.0 == .off }?.1, 8)
        XCTAssertEqual(Set(slots.map { $0.1 }).count, slots.count, "slots are unique")
        XCTAssertEqual(FirmwareLighting.switchProfile(2, slot: 1), Proto.packet([0x14, 0x00, 0x00, 0x00, 2, 1]))
        XCTAssertEqual(FirmwareLighting.saveFlash(slot: 6), Proto.packet([0x13, 0x55, 0x00, 0x00, 6]))
    }

    // MARK: Pictures

    func testUploadDescriptor() {
        // 72×72 RGB565 = 10,368 bytes = 0x002880; key index is 0-based.
        XCTAssertEqual(Proto.uploadDescriptor(size: 10368, checksum: 0x3717, profile: 1, ledno: 2),
                       [0xAA, 0x55, 0x10, 0x80, 0x28, 0x00, 0x17, 0x37, 0x00, 0x00, 0x02, 0x01, 0x02])
        // dial: 240×204×2 = 97,920 = 0x017E80
        XCTAssertEqual(Array(Proto.uploadDescriptor(size: 97_920, checksum: 0, profile: 1, ledno: 0)[3...5]), [0x80, 0x7E, 0x01])
    }

    func testTargetSelection() {
        XCTAssertEqual(Proto.destSelect(dest: 0x04), [0xAA, 0x55, 0x21, 0x04])
        XCTAssertEqual(Proto.destSelect(dest: 0x03), [0xAA, 0x55, 0x21, 0x03])
        XCTAssertEqual(Proto.destQuery, [0xAA, 0x55, 0x22, 0x00])
    }

    func testPictureReset() {
        // one key bitmap per profile slot: D3 of profile 1, all keys of profile 2
        XCTAssertEqual(Proto.resetNumpadPics(0x04, slot: 1), Proto.packet([0x13, 0x42, 0x00, 0x00, 0x04]))
        XCTAssertEqual(Proto.resetNumpadPics(0x0F, slot: 2), Proto.packet([0x13, 0x42, 0x00, 0x00, 0x00, 0x0F]))
    }

    func testRGB565Conversion() throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [r, g, b, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return ctx.makeImage()!
        }
        func first(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> Int {
            // Same size in and out, so nothing is resampled at the edges.
            let bytes = try ImageTools.rgb565(image: solid(r, g, b), width: 8, height: 8)
            return Int(bytes[0]) | Int(bytes[1]) << 8      // little-endian
        }
        XCTAssertEqual(try first(1, 0, 0), 0xF800)
        XCTAssertEqual(try first(0, 1, 0), 0x07E0)
        XCTAssertEqual(try first(0, 0, 1), 0x001F)
        XCTAssertEqual(try first(1, 1, 1), 0xFFFF)
        // The factory blue #0044FF must reach the LCD unchanged (r 0, g 17, b 31).
        XCTAssertEqual(try first(0, 68.0 / 255, 1), 0x023F)
        // The sizes the keyboard expects: 72×72 key picture, 240×204 dial picture.
        XCTAssertEqual(try ImageTools.rgb565(image: solid(0, 0, 0), width: 72, height: 72).count, 10_368)
        XCTAssertEqual(try ImageTools.rgb565(image: solid(0, 0, 0), width: 240, height: 204).count, 97_920)
    }

    // MARK: Queries, dial, actions

    func testQueriesAndDial() {
        XCTAssertEqual(Proto.keepalive, Proto.packet([0x11, 0x14]))
        XCTAssertEqual(Proto.reinit, Proto.packet([0x11, 0x12]))
        XCTAssertEqual(Proto.metric(index: 3, value: 42), Proto.packet([0x11, 0x81, 3, 0, 42]))
        XCTAssertEqual(Proto.volume(level: 7), Proto.packet([0x11, 0x83, 0, 0, 7]))
        let sw = Proto.modeSwitch(deviceBytes: [0xF3, 0xCC, 0x23], mode: .cpu)
        XCTAssertEqual(Array(sw[0...5]), [0x11, 0x14, 0, 1, 2, 0xFF])
        XCTAssertEqual(Array(sw[7...10]), [0xF3, 0xCC, 0x23, 0x91])
        XCTAssertEqual(Proto.MainMode.allCases.map(\.menuByte),
                       [0x01, 0x11, 0x71, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1])
    }

    func testActionWrites() {
        XCTAssertEqual(Proto.actionSlot(button: 2), Proto.packet([0x12, 0x08, 0x00, 0x03]))
        XCTAssertEqual(Array(Proto.actionData(":", type: 0x04).prefix(6)), [0x17, 0xAA, 0x02, 0x00, 0x04, 0x3A])
    }

    func testButtonEvents() {
        func event(_ b42: UInt8) -> [UInt8] { var p = [UInt8](repeating: 0, count: 64); p[0] = 1; p[42] = b42; return p }
        XCTAssertEqual(DeviceState.pressedButton(in: event(0x02)), 0)
        XCTAssertEqual(DeviceState.pressedButton(in: event(0x04)), 1)
        XCTAssertEqual(DeviceState.pressedButton(in: event(0x08)), 2)
        XCTAssertEqual(DeviceState.pressedButton(in: event(0x10)), 3)
        XCTAssertNil(DeviceState.pressedButton(in: event(0)))
        XCTAssertNil(DeviceState.pressedButton(in: event(0x20)))
        var notAnEvent = event(0x02); notAnEvent[0] = 0x11
        XCTAssertNil(DeviceState.pressedButton(in: notAnEvent))
    }

    func testStateParsing() {
        // A real `11 14` reply from an Everest Max with numpad and dock.
        let raw: [UInt8] = [0x11, 0x14, 0, 0, 1, 0xFF, 0x15, 0xF3, 0xCC, 0x23, 0x11, 0x1E, 0, 0x1E, 0, 1] +
            [UInt8](repeating: 0, count: 48)
        let s = DeviceState(raw: raw)
        XCTAssertEqual(s.deviceBytes, [0xF3, 0xCC, 0x23])
        XCTAssertEqual(s.modeByte, 0x11)
    }

    /// Night mode: the settings block echoed with the write flag, only the
    /// ten display brightness bytes changed.
    func testDisplayBrightness() throws {
        var reply = Proto.packet([0x11, 0x14, 0x00, 0x00, 0x02, 0xFF, 0x00, 0xF3, 0xCC, 0x23, 0x11, 0x1E])
        for i in 23...32 { reply[i] = 0xE4 }
        let off = try XCTUnwrap(Proto.displayBrightness(from: reply, byte: Proto.displaysOff))
        XCTAssertEqual(Array(off[0...3]), [0x11, 0x14, 0x00, 0x01], "write flag")
        XCTAssertEqual(Array(off[4...22]), Array(reply[4...22]), "the keyboard's own bytes are kept")
        XCTAssertTrue(off[23...32].allSatisfy { $0 == 0x80 })
        XCTAssertTrue(off[33...].allSatisfy { $0 == 0 })
        let back = try XCTUnwrap(Proto.displayBrightness(from: reply, byte: Proto.displaysFollowLighting))
        XCTAssertTrue(back[23...32].allSatisfy { $0 == 0x00 })
        XCTAssertNil(Proto.displayBrightness(from: Proto.packet([0x11, 0x00]), byte: 0x80), "not a settings reply")
    }
}
