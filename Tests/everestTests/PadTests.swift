import XCTest
@testable import everest

/// DisplayPad packets, byte for byte (from Mountain's SDK and verified on a
/// pad running firmware 8), the command allow-list, and the config.
final class PadTests: XCTestCase {
    private func hex(_ p: [UInt8], _ n: Int = 12) -> String {
        p.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func testCommands() {
        XCTAssertEqual(hex(PadProto.enable, 6), "11 80 00 00 01 00")
        XCTAssertEqual(hex(PadProto.firmwareInfo, 4), "11 00 00 00")
        XCTAssertEqual(hex(PadProto.brightnessQuery, 5), "12 00 00 01 00")
        XCTAssertEqual(hex(PadProto.setBrightness(75), 6), "12 03 00 00 4b 00")
        XCTAssertEqual(hex(PadProto.keyImage(0)), "21 00 00 00 00 3d 00 00 65 65 00 00")
        XCTAssertEqual(hex(PadProto.keyImage(11)), "21 00 00 00 0b 3d 00 00 65 65 00 00")
        for p in [PadProto.enable, PadProto.setBrightness(30), PadProto.keyImage(5)] { XCTAssertEqual(p.count, 64) }
    }

    func testBrightnessIsAnyPercentage() {
        XCTAssertEqual(PadProto.brightnessLevel(-5), 0)
        XCTAssertEqual(PadProto.brightnessLevel(37), 37)
        XCTAssertEqual(PadProto.brightnessLevel(140), 100)
        XCTAssertEqual(hex(PadProto.setBrightness(37), 5), "12 03 00 00 25")
        XCTAssertTrue(PadProto.isAllowed(PadProto.setBrightness(37)))
    }

    /// The backlight ignores levels between 0 and 100: pictures are darkened.
    func testBrightnessDarkensThePicture() {
        XCTAssertEqual(PadProto.backlight(for: 0), 0)
        XCTAssertEqual(PadProto.backlight(for: 5), 100)
        let white = PadProto.solid(r: 255, g: 255, b: 255)
        XCTAssertEqual(PadProto.dim(white, percent: 100), white)
        XCTAssertEqual(Array(PadProto.dim(white, percent: 50).prefix(3)), [128, 128, 128])
        XCTAssertEqual(Array(PadProto.dim(white, percent: 5).prefix(3)), [13, 13, 13])
        XCTAssertTrue(PadProto.dim(white, percent: 0).allSatisfy { $0 == 0 })
    }

    func testAllowListRefusesFlashAndFirmwareCommands() {
        for p in [PadProto.enable, PadProto.firmwareInfo, PadProto.brightnessQuery, PadProto.sleepQuery,
                  PadProto.setBrightness(50), PadProto.keyImage(0), PadProto.keyImage(11)] {
            XCTAssertTrue(PadProto.isAllowed(p), hex(p))
        }
        let refused: [[UInt8]] = [
            [0x30, 0xAA, 0x55],                     // firmware update / reboot
            [0xAA, 0x55, 0x21],
            [0x1A, 0x00], [0x1B, 0x00],             // sector write / erase
            [0x13, 0x40], [0x13, 0x60], [0x13, 0x61],  // erase profiles, keys, pictures
            [0x21, 0x01, 0x00, 0x00, 0x00, 0x3D],   // picture to flash
            [0x21, 0x02, 0x00, 0x00],               // boot logo
            [0x21, 0x00, 0x00, 0x01, 0x3D],         // whole panel (not used)
            [0x21, 0x00, 0x00, 0x00, 0x0C, 0x3D, 0x00, 0x00, 0x65, 0x65],  // key 12 does not exist
            [0x12, 0x03, 0x00, 0x00, 0x65],         // above 100 %
            [0x11, 0x80, 0x00, 0x00, 0x00],         // host mode off
            [0x14, 0x00, 0x00, 0x00, 0x01],         // profile switch
            [0x23, 0x01],                           // logo
        ]
        for head in refused {
            XCTAssertFalse(PadProto.isAllowed(PadProto.packet(head)), hex(head))
        }
        XCTAssertFalse(PadProto.isAllowed([0x11, 0x00]), "not padded to 64 bytes")
    }

    func testReplies() {
        let fw = PadProto.packet([0x11, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x06, 0x00, 0x01])
        XCTAssertEqual(PadProto.firmwareVersion(fw), 0x0008)
        XCTAssertEqual(PadProto.firmwareString(0x0008), "8")
        XCTAssertEqual(PadProto.brightness(PadProto.packet([0x12, 0x00, 0x00, 0x01, 0x01, 0x4B])), 75)
        XCTAssertTrue(PadProto.isImageReady(PadProto.packet([0x21, 0x00, 0x00, 0x00, 0x00, 0x3D])))
        XCTAssertTrue(PadProto.isImageDone(PadProto.packet([0x21, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertFalse(PadProto.isImageReady(PadProto.packet([0x21, 0x00, 0xFF, 0xFF])))
        XCTAssertTrue(PadProto.isError(PadProto.packet([0xFF, 0xAA])))
    }

    /// Captured on hardware: one packet per press, all bits clear on release.
    func testKeyEvents() {
        func event(_ b42: UInt8, _ b47: UInt8) -> [UInt8] {
            var p = PadProto.packet([0x01]); p[42] = b42; p[47] = b47; return p
        }
        XCTAssertEqual(PadProto.pressedKeys(event(0x02, 0)), [0])
        XCTAssertEqual(PadProto.pressedKeys(event(0x80, 0)), [6])
        XCTAssertEqual(PadProto.pressedKeys(event(0, 0x01)), [7])
        XCTAssertEqual(PadProto.pressedKeys(event(0, 0x10)), [11])
        XCTAssertEqual(PadProto.pressedKeys(event(0x06, 0x11)), [0, 1, 7, 11])
        XCTAssertEqual(PadProto.pressedKeys(event(0, 0)), [])
        XCTAssertEqual(PadProto.pressedKeys(PadProto.packet([0x11, 0x00])), [])
    }

    /// No header: the first pixel is byte 0 (with the community's 306-byte
    /// header the bottom row was lost on hardware).
    func testPixelStream() {
        let red = PadProto.solid(r: 255, g: 0, b: 0)
        XCTAssertEqual(red.count, 102 * 102 * 3)
        XCTAssertEqual(Array(red.prefix(3)), [0, 0, 255], "BGR")
        let stream = PadProto.pixelStream(bgr: red)
        XCTAssertEqual(stream.count, 31 * 1024)
        XCTAssertEqual(Array(stream.prefix(3)), [0, 0, 255])
        XCTAssertEqual(Array(stream[(102 * 102 * 3 - 3)..<(102 * 102 * 3)]), [0, 0, 255])
        XCTAssertTrue(stream[(102 * 102 * 3)...].allSatisfy { $0 == 0 })
        XCTAssertLessThanOrEqual(102 * 102 * 3, PadProto.keyImageBlocks * 512, "the announced size covers every row")
    }

    func testImageConversion() throws {
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let bgr = try ImageTools.padBGR(image: ctx.makeImage()!)
        XCTAssertEqual(bgr.count, 102 * 102 * 3)
        XCTAssertEqual(Array(bgr.prefix(3)), [255, 0, 0], "blue is stored first")
    }

    func testOldConfigGetsTwelveBlankPadKeys() throws {
        let json = #"{"profiles":[{"id":1,"name":"Main","symbol":"keyboard","color":"8b5cf6","buttons":[],"apps":[]}]}"#
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.padButtons.count, 12)
        XCTAssertTrue(cfg.padButtons.allSatisfy { $0.action.type == .noAction && $0.iconPath == nil })
        XCTAssertEqual(cfg.padBrightness, 75)
    }

    func testPadKeysArePerProfile() throws {
        var cfg = Config()
        cfg.profiles.append(ProfileConfig(id: 2, name: "Two"))
        var keys = cfg.padButtons
        keys[3].action = ButtonAction(type: .url, value: "https://example.com")
        cfg.padButtons = keys
        let round = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(round.padButtons(for: 1)[3].action.value, "https://example.com")
        XCTAssertEqual(round.padButtons(for: 2)[3].action.type, .noAction)
        XCTAssertEqual(KeyTarget.pad(11).label, "P12")
        XCTAssertEqual(KeyTarget.dkey(0).label, "D1")
    }

    func testBusyMarkersArePerProcess() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("everest-pad-\(UUID().uuidString)")
        setenv("EVEREST_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("EVEREST_CONFIG_DIR"); try? FileManager.default.removeItem(at: dir) }
        PadBusy.set()
        XCTAssertFalse(PadBusy.active, "our own marker does not silence us")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Another live process (launchd, pid 1, always exists).
        try Data().write(to: dir.appendingPathComponent(".pad-busy.1"))
        XCTAssertTrue(PadBusy.active)
        // A process that no longer exists does not count.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".pad-busy.1"))
        try Data().write(to: dir.appendingPathComponent(".pad-busy.999999"))
        XCTAssertFalse(PadBusy.active)
        PadBusy.clear()
    }

    func testPadStateRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("everest-pad-\(UUID().uuidString)")
        setenv("EVEREST_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("EVEREST_CONFIG_DIR"); try? FileManager.default.removeItem(at: dir) }
        PadState(status: .unsupported, firmware: "9").publish()
        XCTAssertEqual(PadState.read(), PadState(status: .unsupported, firmware: "9"))
    }

    /// Live tiles: every metric draws at the key size and converts to the
    /// pad's format; the signature changes only with the shown text.
    func testLiveTiles() throws {
        var sample = MetricsSample()
        sample.cpu = 37; sample.gpu = 5; sample.ram = 64; sample.disk = 81; sample.networkMBs = 12; sample.volumeLevel = 60
        let dump = ProcessInfo.processInfo.environment["EVEREST_TILE_DUMP"]
        for m in LiveMetric.allCases {
            let img = try XCTUnwrap(LiveTiles.image(m, sample: sample), m.rawValue)
            XCTAssertEqual(img.width, 102)
            XCTAssertEqual(try ImageTools.padBGR(image: img).count, 102 * 102 * 3)
            if let dump, let big = LiveTiles.image(m, sample: sample, side: 204) {
                let url = URL(fileURLWithPath: dump).appendingPathComponent("tile-\(m.rawValue).png")
                let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, big, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        XCTAssertEqual(LiveTiles.signature(.cpu, sample: sample), "live:cpu:37%")
        var other = sample; other.ram = 10
        XCTAssertEqual(LiveTiles.signature(.cpu, sample: other), LiveTiles.signature(.cpu, sample: sample))
    }

    func testLiveKeyRoundTrip() throws {
        var b = PadKeys.button(0)
        b.live = .ram
        let back = try JSONDecoder().decode(ButtonConfig.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back.live, .ram)
        XCTAssertNil(try JSONDecoder().decode(ButtonConfig.self, from: JSONEncoder().encode(PadKeys.button(1))).live)
    }
}
