import Foundation

struct ButtonAction: Codable {
    var type: String     // shell | url | open | app | keypress | text | none
    var value: String
}

struct ButtonConfig: Codable {
    var name: String?
    /// The name in the language in use (factory names are stored in whatever
    /// language was active when they were created).
    var title: String? { name.map(L10n.displayName) }
    var icon: Int?
    /// Path of the image last uploaded to this button's display, so the UI
    /// can preview it.
    var iconPath: String?
    var action: ButtonAction
}

/// What the lighting page shows on launch.
struct LightingConfig: Codable {
    enum Source: String, Codable { case firmware, mac }
    var source: Source = .firmware
    var firmware = FirmwareLighting()
    var mac = LedEffect()
}

/// What D1–D4 do out of the box. Base Camp's default profile pairs each
/// display key with a picture (`default-profile/2_dlogo`, `4_explorer`,
/// `6_sleep`, `3_electic`) and a function: Base Camp itself, the file
/// explorer, sleep, and the task manager (`task_manager.png` is the same
/// pulse glyph as D4's picture). These are the macOS equivalents.
enum FactoryKeys {
    static var names: [String] { ["Everest", "Finder", tr("factory.sleep"), tr("factory.activityMonitor")] }

    static let actions: [ButtonAction] = [
        ButtonAction(type: "shell", value: "open -b local.everest-mac"),                       // Base Camp → this app
        ButtonAction(type: "app", value: "/System/Library/CoreServices/Finder.app"),           // File Explorer
        ButtonAction(type: "shell", value: "pmset sleepnow"),                                  // Sleep
        ButtonAction(type: "app", value: "/System/Applications/Utilities/Activity Monitor.app"), // Task Manager
    ]

    static func button(_ i: Int) -> ButtonConfig {
        ButtonConfig(name: names[i], icon: 7, iconPath: nil, action: actions[i])
    }

    static var buttons: [ButtonConfig] { (0..<4).map(button) }
}

/// An app that switches the keyboard to a profile when it comes to the front.
struct LinkedApp: Codable, Hashable {
    var bundleID: String
    var name: String
    var path: String
}

/// One of the keyboard's five hardware profiles (selectable from the dial's
/// Profile menu). The keyboard keeps lighting, key remaps and the display-key
/// images per profile; the app adds the D1–D4 actions, the dial mode and the
/// apps that switch to it.
struct ProfileConfig: Codable, Identifiable {
    var id: Int                                  // hardware profile 1…5
    var name: String
    var symbol: String = "keyboard"
    var color: String = "8b5cf6"
    var buttons: [ButtonConfig] = FactoryKeys.buttons
    var lighting: LightingConfig?
    var dialMode: String?                        // applied when switching to it
    var apps: [LinkedApp] = []
    var title: String { L10n.displayName(name) }

    static let palette = ["8b5cf6", "ec4899", "06b6d4", "10b981", "f59e0b"]
}

struct Config: Codable {
    var clockStyle: String = "analog"        // analog | digital
    var clockFormat: String = "24h"          // 12h | 24h
    var dialImagePath: String?               // last dial image, for the preview
    var monitorMode: Bool = true             // push metrics in the listen loop
    var mainDisplayMode: String = "clock"    // mode applied when listen starts
    var applyClockOnStart: Bool = true
    /// The keyboard keeps its own action for D1–D4 (a Windows-style shortcut:
    /// ⌘1… on a Mac) that fires next to ours. By default the app and the
    /// daemon overwrite them with a no-op; set this to keep the factory ones.
    var keepFlashActions: Bool = false
    var profiles: [ProfileConfig] = [ProfileConfig(id: 1, name: tr("profile.main"))]
    /// The profile the app is showing — follows the keyboard's active one.
    var selectedProfile: Int = 1
    /// Layout chosen by hand (nil = trust what the keyboard reports).
    var layoutOverride: KeyboardLayout?
    /// Last layout the keyboard reported, used until it is detected again.
    var lastLayout: KeyboardLayout?
    /// Run the D1–D4 listener whenever the app runs (and restart it if it dies).
    var daemonEnabled: Bool = true
    /// Closing the window keeps Everest in the menu bar instead of quitting.
    var keepRunning: Bool = true
    /// Switch profiles automatically when a linked app comes to the front.
    var autoSwitch: Bool = true
    /// Profile to return to when the front app has no profile of its own.
    var defaultProfile: Int = 1
    /// Interface language (`Language.rawValue`); nil follows the system.
    var language: String?

    init() {}

    // MARK: Selected profile shortcuts

    func profileIndex(_ id: Int) -> Int? { profiles.firstIndex { $0.id == id } }

    /// D1–D4 of the selected profile.
    var buttons: [ButtonConfig] {
        get { profileIndex(selectedProfile).map { profiles[$0].buttons } ?? FactoryKeys.buttons }
        set {
            if let i = profileIndex(selectedProfile) { profiles[i].buttons = newValue }
        }
    }

    var lighting: LightingConfig? {
        get { profileIndex(selectedProfile).flatMap { profiles[$0].lighting } }
        set {
            if let i = profileIndex(selectedProfile) { profiles[i].lighting = newValue }
        }
    }

    /// D1–D4 for a hardware profile (the daemon follows the keyboard).
    func buttons(for profile: Int) -> [ButtonConfig] {
        profileIndex(profile).map { profiles[$0].buttons } ?? buttons
    }

    // MARK: Codable (with migration from the single-profile format)

    enum CodingKeys: String, CodingKey {
        case clockStyle, clockFormat, dialImagePath, monitorMode, mainDisplayMode, applyClockOnStart
        case language, layoutOverride, lastLayout, keepFlashActions, daemonEnabled, keepRunning, profiles, selectedProfile, autoSwitch, defaultProfile
        case buttons, lighting   // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clockStyle = try c.decodeIfPresent(String.self, forKey: .clockStyle) ?? "analog"
        clockFormat = try c.decodeIfPresent(String.self, forKey: .clockFormat) ?? "24h"
        dialImagePath = try c.decodeIfPresent(String.self, forKey: .dialImagePath)
        monitorMode = try c.decodeIfPresent(Bool.self, forKey: .monitorMode) ?? true
        mainDisplayMode = try c.decodeIfPresent(String.self, forKey: .mainDisplayMode) ?? "clock"
        applyClockOnStart = try c.decodeIfPresent(Bool.self, forKey: .applyClockOnStart) ?? true
        keepFlashActions = try c.decodeIfPresent(Bool.self, forKey: .keepFlashActions) ?? false
        layoutOverride = try c.decodeIfPresent(KeyboardLayout.self, forKey: .layoutOverride)
        lastLayout = try c.decodeIfPresent(KeyboardLayout.self, forKey: .lastLayout)
        daemonEnabled = try c.decodeIfPresent(Bool.self, forKey: .daemonEnabled) ?? true
        keepRunning = try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? true
        selectedProfile = try c.decodeIfPresent(Int.self, forKey: .selectedProfile) ?? 1
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? true
        defaultProfile = try c.decodeIfPresent(Int.self, forKey: .defaultProfile) ?? 1
        language = try c.decodeIfPresent(String.self, forKey: .language)
        if let list = try c.decodeIfPresent([ProfileConfig].self, forKey: .profiles), !list.isEmpty {
            profiles = list
        } else {
            // Older files: one set of buttons and lighting → profile 1.
            var p = ProfileConfig(id: 1, name: tr("profile.main"))
            if let b = try c.decodeIfPresent([ButtonConfig].self, forKey: .buttons), b.count >= 4 { p.buttons = b }
            p.lighting = try c.decodeIfPresent(LightingConfig.self, forKey: .lighting)
            profiles = [p]
        }
        if profileIndex(selectedProfile) == nil { selectedProfile = profiles[0].id }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clockStyle, forKey: .clockStyle)
        try c.encode(clockFormat, forKey: .clockFormat)
        try c.encodeIfPresent(dialImagePath, forKey: .dialImagePath)
        try c.encode(monitorMode, forKey: .monitorMode)
        try c.encode(mainDisplayMode, forKey: .mainDisplayMode)
        try c.encode(applyClockOnStart, forKey: .applyClockOnStart)
        try c.encode(keepFlashActions, forKey: .keepFlashActions)
        try c.encodeIfPresent(layoutOverride, forKey: .layoutOverride)
        try c.encodeIfPresent(lastLayout, forKey: .lastLayout)
        try c.encode(daemonEnabled, forKey: .daemonEnabled)
        try c.encode(keepRunning, forKey: .keepRunning)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(selectedProfile, forKey: .selectedProfile)
        try c.encode(autoSwitch, forKey: .autoSwitch)
        try c.encode(defaultProfile, forKey: .defaultProfile)
        try c.encodeIfPresent(language, forKey: .language)
    }

    /// `~/.config/everest-mac`, or `$EVEREST_CONFIG_DIR` (the tests use it so
    /// they never touch a real configuration).
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["EVEREST_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/everest-mac", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: file) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            stderr("warning: \(file.path) is invalid JSON (\(error)) — using defaults")
            return Config()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
            try enc.encode(self).write(to: Config.file)
        } catch {
            stderr("warning: could not write \(Config.file.path): \(error)")
        }
    }
}

enum ConfigCommand {
    static func show() {
        let cfg = Config.load()
        print("Config file: \(Config.file.path)")
        if !FileManager.default.fileExists(atPath: Config.file.path) {
            print("(not created yet — run `everest init-config`)")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    static func initFile() {
        if FileManager.default.fileExists(atPath: Config.file.path) {
            print("Config already exists: \(Config.file.path)")
            return
        }
        // The factory behaviour of D1–D4 (see FactoryKeys).
        Config().save()
        print("Wrote default config: \(Config.file.path)")
    }
}
