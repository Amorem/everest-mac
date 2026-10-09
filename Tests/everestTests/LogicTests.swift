import XCTest
@testable import everest

/// Configuration, profiles and rendering — everything that needs no keyboard.
final class LogicTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("everest-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("EVEREST_CONFIG_DIR", dir.path, 1)
    }

    override func tearDown() {
        unsetenv("EVEREST_CONFIG_DIR")
        try? FileManager.default.removeItem(at: dir)
        LedLayout.use(.uk)
    }

    // MARK: Config file

    func testSaveIsPrivateAndReadable() throws {
        var cfg = Config()
        cfg.clockFormat = "12h"
        cfg.save()
        let attrs = try FileManager.default.attributesOfItem(atPath: Config.file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(Config.load().clockFormat, "12h")
        XCTAssertNotNil(Config.fileStamp)
    }

    /// A typo in a hand-edited file must not be replaced by the defaults.
    func testInvalidFileIsKeptAside() throws {
        try FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try Data(#"{"clockFormat": 12h}"#.utf8).write(to: Config.file)
        XCTAssertEqual(Config.load().clockFormat, "24h", "defaults")
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.json.bad-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Config.file.path))
    }

    /// The JSON keeps the plain strings; an unknown type does not make the
    /// file unreadable.
    func testActionKindsInJSON() throws {
        let data = try JSONEncoder().encode(ButtonAction(type: .noAction, value: ""))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""type":"none""#))
        let odd = try JSONDecoder().decode(ButtonAction.self, from: Data(#"{"type":"teleport","value":"x"}"#.utf8))
        XCTAssertEqual(odd.type, .noAction)
        let app = try JSONDecoder().decode(ButtonAction.self, from: Data(#"{"type":"app","value":"/A.app"}"#.utf8))
        XCTAssertEqual(app.type, .app)
    }

    /// Profile keys: next / previous wrap around the configured profiles
    /// (in id order, gaps allowed), an id must exist.
    func testProfileRequests() {
        var cfg = Config()
        cfg.profiles = [1, 2, 4].map { ProfileConfig(id: $0, name: "P\($0)") }
        XCTAssertEqual(ProfileRequest.resolve("next", current: 1, config: cfg), 2)
        XCTAssertEqual(ProfileRequest.resolve("next", current: 2, config: cfg), 4)
        XCTAssertEqual(ProfileRequest.resolve("next", current: 4, config: cfg), 1)
        XCTAssertEqual(ProfileRequest.resolve("previous", current: 1, config: cfg), 4)
        XCTAssertEqual(ProfileRequest.resolve("4", current: 1, config: cfg), 4)
        XCTAssertNil(ProfileRequest.resolve("3", current: 1, config: cfg), "no profile 3")
        XCTAssertNil(ProfileRequest.resolve("teleport", current: 1, config: cfg))
        ProfileRequest.post("next")
        XCTAssertEqual(ProfileRequest.take(), "next")
        XCTAssertNil(ProfileRequest.take(), "taken once")
        let json = try? JSONEncoder().encode(ButtonAction(type: .profile, value: "next"))
        XCTAssertTrue(json.map { String(decoding: $0, as: UTF8.self).contains(#""type":"profile""#) } ?? false)
    }

    /// Night mode state: written atomically, read back by every process.
    func testNightModeState() {
        XCTAssertFalse(NightMode.active, "no file: day")
        NightMode.write(NightMode.State(active: true, mutedByUs: true, savedVolume: nil))
        XCTAssertEqual(NightMode.read(), NightMode.State(active: true, mutedByUs: true, savedVolume: nil))
        XCTAssertTrue(NightMode.active)
        XCTAssertEqual(ActionKind(rawValue: "night"), .night)
    }

    // MARK: Factory defaults

    func testFactoryKeys() {
        let keys = FactoryKeys.buttons
        XCTAssertEqual(keys.count, 4)
        XCTAssertEqual(keys[0].action.type, .shell)
        XCTAssertEqual(keys[0].action.value, "open -b local.everest-mac")
        XCTAssertEqual(keys[1].action.value, "/System/Library/CoreServices/Finder.app")
        XCTAssertEqual(keys[2].action.value, "pmset sleepnow")
        XCTAssertEqual(keys[3].action.value, "/System/Applications/Utilities/Activity Monitor.app")
        XCTAssertTrue(keys.allSatisfy { $0.iconPath == nil }, "a factory key has no custom picture")
        XCTAssertEqual(Config().buttons.map(\.action.value), keys.map(\.action.value))
    }

    func testFactoryPicturesAreEmbedded() {
        for i in 0..<4 {
            let img = FactoryIcons.image(i)
            XCTAssertNotNil(img, "D\(i + 1)")
            XCTAssertEqual(img?.size.width, 256)
        }
        XCTAssertNil(FactoryIcons.image(4))
        XCTAssertGreaterThan(MountainMark.image.size.width, 100, "the logo mark is embedded")
    }

    // MARK: Config

    func testRoundTrip() throws {
        var cfg = Config()
        cfg.profiles[0].name = "Coding"
        cfg.profiles.append(ProfileConfig(id: 2, name: "Music"))
        cfg.profiles[1].apps = [LinkedApp(bundleID: "com.apple.logic10", name: "Logic Pro", path: "/Applications/Logic Pro.app")]
        cfg.layoutOverride = .french
        cfg.daemonEnabled = false
        cfg.save()
        let back = Config.load()
        XCTAssertEqual(back.profiles.map(\.name), ["Coding", "Music"])
        XCTAssertEqual(back.profiles[1].apps.first?.bundleID, "com.apple.logic10")
        XCTAssertEqual(back.layoutOverride, .french)
        XCTAssertFalse(back.daemonEnabled)
        XCTAssertTrue(back.keepRunning, "defaults survive")
    }

    func testMigrationFromSingleProfileFile() throws {
        // The format before profiles existed: buttons and lighting at the top.
        let legacy = """
        {"clockStyle":"digital","clockFormat":"12h","monitorMode":false,"mainDisplayMode":"cpu",
         "applyClockOnStart":true,"clearFlashActions":false,
         "buttons":[
          {"name":"One","action":{"type":"url","value":"https://example.com"}},
          {"name":"Two","action":{"type":"none","value":""}},
          {"name":"Three","action":{"type":"none","value":""}},
          {"name":"Four","action":{"type":"keypress","value":"cmd+shift+4"}}]}
        """
        try legacy.write(to: Config.file, atomically: true, encoding: .utf8)
        let cfg = Config.load()
        XCTAssertEqual(cfg.profiles.count, 1)
        XCTAssertEqual(cfg.profiles[0].id, 1)
        XCTAssertEqual(cfg.buttons.map { $0.name ?? "" }, ["One", "Two", "Three", "Four"])
        XCTAssertEqual(cfg.buttons[3].action.value, "cmd+shift+4")
        XCTAssertEqual(cfg.clockStyle, "digital")
        XCTAssertEqual(cfg.mainDisplayMode, "cpu")
        XCTAssertFalse(cfg.monitorMode)
    }

    func testMissingOrBrokenFile() throws {
        XCTAssertEqual(Config.load().profiles.count, 1)
        try "{ not json".write(to: Config.file, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load().buttons.count, 4, "a broken file falls back to defaults")
    }

    func testButtonsFollowTheSelectedProfile() {
        var cfg = Config()
        var coding = ProfileConfig(id: 3, name: "Coding")
        coding.buttons[0].name = "Build"
        cfg.profiles.append(coding)
        cfg.selectedProfile = 3
        XCTAssertEqual(cfg.buttons[0].name, "Build")
        XCTAssertEqual(cfg.buttons(for: 1)[0].name, "Everest")
        XCTAssertEqual(cfg.buttons(for: 5)[0].name, "Build", "an unknown profile uses the selected one")
    }

    // MARK: Profile switching

    private func linkedConfig() -> Config {
        var cfg = Config()
        var music = ProfileConfig(id: 2, name: "Music")
        music.apps = [LinkedApp(bundleID: "com.example.logic", name: "Logic", path: "/x")]
        cfg.profiles.append(music)
        cfg.defaultProfile = 1
        return cfg
    }

    func testAutoSwitch() {
        let cfg = linkedConfig()
        let sw = AutoSwitcher()
        XCTAssertEqual(sw.update(frontApp: "com.example.logic", current: 1, config: cfg), 2, "linked app → its profile")
        XCTAssertNil(sw.update(frontApp: "com.example.logic", current: 2, config: cfg), "no repeat")
        XCTAssertEqual(sw.update(frontApp: "com.apple.finder", current: 2, config: cfg), 1, "leaving it → default profile")
        XCTAssertNil(sw.update(frontApp: "com.apple.mail", current: 1, config: cfg))
    }

    func testAutoSwitchLeavesManualChoicesAlone() {
        let cfg = linkedConfig()
        let sw = AutoSwitcher()
        // the profile was picked on the dial: an unrelated app must not undo it
        XCTAssertNil(sw.update(frontApp: "com.apple.finder", current: 3, config: cfg))
    }

    func testAutoSwitchOffAndSelf() {
        var cfg = linkedConfig()
        let sw = AutoSwitcher()
        XCTAssertNil(sw.update(frontApp: "local.everest-mac", current: 1, config: cfg), "our own window is ignored")
        cfg.autoSwitch = false
        XCTAssertNil(AutoSwitcher().update(frontApp: "com.example.logic", current: 1, config: cfg))
    }

    func testProfileSlotAfterSwitch() {
        var p = ProfileConfig(id: 2, name: "x")
        XCTAssertEqual(ProfileSwitch.slot(for: p), 0)
        var l = LightingConfig(); l.source = .firmware; l.firmware.effect = .tornado
        p.lighting = l
        XCTAssertEqual(ProfileSwitch.slot(for: p), 2)
        l.source = .mac
        p.lighting = l
        XCTAssertEqual(ProfileSwitch.slot(for: p), 6, "Mac effects live in the custom slot")
    }

    // MARK: Colour

    func testRGB() {
        XCTAssertEqual(RGB(hex: "#ff8000"), RGB(r: 255, g: 128, b: 0))
        XCTAssertNil(RGB(hex: "xyz"))
        XCTAssertEqual(RGB(r: 1, g: 2, b: 255).hex, "0102ff")
        XCTAssertEqual(RGB.mix(.black, .white, 0), .black)
        XCTAssertEqual(RGB.mix(.black, .white, 1), .white)
        XCTAssertEqual(RGB.scale(.white, 0), .black)
        XCTAssertEqual(RGB.scale(.white, 1), .white)
        XCTAssertEqual(RGB.add(RGB(r: 200, g: 200, b: 200), RGB(r: 200, g: 200, b: 200)), .white, "clips")
        XCTAssertEqual(RGB.hsv(0), RGB(r: 255, g: 0, b: 0))
    }

    // MARK: Rendering

    func testEveryEffectRendersInRange() {
        for layout in [KeyboardLayout.us, .uk] {
            LedLayout.use(layout)
            let used = Set(LedLayout.usedIndices)
            for kind in LedEffect.Kind.allCases {
                for t in [0.0, 1.3, 7.9] {
                    var e = LedEffect(); e.kind = kind
                    let f = LedRenderer.render(e, time: t)
                    XCTAssertEqual(f.main.count, LedLayout.mainLedCount)
                    XCTAssertEqual(f.side.count, LedLayout.sideLedCount)
                    // LEDs without a key (e.g. 111 on an ANSI board) stay dark
                    for i in 0..<LedLayout.mainLedCount where !used.contains(i) {
                        XCTAssertEqual(f.main[i], .black, "\(layout) \(kind): LED \(i) has no key")
                    }
                }
            }
        }
    }

    func testBrightnessAndOff() {
        for kind in LedEffect.Kind.allCases {
            var e = LedEffect(); e.kind = kind; e.brightness = 0
            let f = LedRenderer.render(e, time: 2)
            XCTAssertTrue((f.main + f.side).allSatisfy { $0 == .black }, "\(kind) at brightness 0")
        }
        var off = LedEffect(); off.kind = .off
        XCTAssertTrue(LedRenderer.render(off, time: 1).main.allSatisfy { $0 == .black })
    }

    func testSolidAndPainting() {
        var e = LedEffect(); e.kind = .solid; e.palette = [RGB(r: 10, g: 20, b: 30)]
        let f = LedRenderer.render(e, time: 0)
        XCTAssertEqual(f.main[LedLayout.usedIndices[0]], RGB(r: 10, g: 20, b: 30))
        e.perKey = [41: RGB(r: 255, g: 0, b: 0)]
        let g = LedRenderer.render(e, time: 0)
        XCTAssertEqual(g.main[41], RGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(g.main[0], .black, "unpainted keys stay dark")
    }

    func testFirmwareSimulationRenders() {
        for effect in FirmwareLighting.Effect.allCases {
            var fw = FirmwareLighting(); fw.effect = effect
            let f = LedRenderer.render(fw, time: 1.5)
            XCTAssertEqual(f.main.count, LedLayout.mainLedCount)
            if effect == .off { XCTAssertTrue(f.main.allSatisfy { $0 == .black }) }
        }
    }

    func testDeterministicFrames() {
        var e = LedEffect(); e.kind = .aurora
        XCTAssertEqual(LedRenderer.render(e, time: 3.2).main, LedRenderer.render(e, time: 3.2).main)
    }

    // MARK: Misc

    func testFlashBusyMarker() {
        XCTAssertFalse(FlashBusy.active)
        FlashBusy.set()
        XCTAssertTrue(FlashBusy.active)
        FlashBusy.clear()
        XCTAssertFalse(FlashBusy.active)
    }

    func testPresets() {
        XCTAssertEqual(Set(ButtonPreset.all.map(\.id)).count, ButtonPreset.all.count, "preset ids are unique")
        for p in ButtonPreset.all {
            guard let action = p.action, action.type != .night else { continue }   // night mode takes no value
            XCTAssertFalse(action.value.isEmpty, "\(p.id) has an action value")
            XCTAssertTrue([ActionKind.keypress, .shell, .app].contains(action.type), "\(p.id): \(action.type)")
        }
    }
}
