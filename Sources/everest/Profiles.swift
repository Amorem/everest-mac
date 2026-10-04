import AppKit
import Foundation

/// Hardware profiles, the way Base Camp drives them.
///
/// The Everest Max has five profiles (the dial's *Profile* menu cycles
/// them). Base Camp's profiles map 1:1 onto them (`Profile.Id` =
/// `FWInfo.currentlyProfileIndex`); switching is `SwitchProfile(id, slot)`
/// with the slot of the profile's active lighting effect, and a profile can be
/// linked to a program that switches to it when it starts (`LaunchPadExe`).
/// On the Mac the trigger is the front app instead of a process start.
enum ProfileSwitch {
    static let maxProfiles = 5

    /// Lighting slot to land on: the built-in effect's slot, or the custom
    /// slot (6) for Mac-rendered effects.
    static func slot(for profile: ProfileConfig) -> UInt8 {
        guard let l = profile.lighting else { return 0 }
        return l.source == .mac ? 6 : l.firmware.effect.slot
    }

    /// Make a profile active on the keyboard and apply its dial mode.
    static func activate(_ profile: ProfileConfig, keyboard kb: Keyboard) {
        kb.send(FirmwareLighting.switchProfile(UInt8(profile.id), slot: slot(for: profile)), wait: 0.3)
        if let raw = profile.dialMode, let mode = Proto.MainMode(rawValue: raw) {
            kb.setMainMode(mode)
        }
    }

    /// The profile linked to an app, if any.
    static func profile(forApp bundleID: String?, in cfg: Config) -> ProfileConfig? {
        guard let bundleID else { return nil }
        return cfg.profiles.first { p in p.apps.contains { $0.bundleID == bundleID } }
    }
}

/// Follows the front app and decides when to switch. Pure logic: the caller
/// performs the switch, so the daemon and the app share the same rules.
final class AutoSwitcher {
    private var lastApp: String?
    /// Set when we switched because of an app, so leaving it returns to the
    /// default profile; a profile picked by hand on the dial is left alone.
    private var autoSwitched = false

    /// Returns the profile to switch to, or nil to stay.
    func update(frontApp: String?, current: Int, config cfg: Config) -> Int? {
        guard cfg.autoSwitch, frontApp != lastApp else { return nil }
        lastApp = frontApp
        // Our own windows (the app itself) don't count.
        if frontApp == Bundle.main.bundleIdentifier || frontApp == "local.everest-mac" { return nil }
        if let p = ProfileSwitch.profile(forApp: frontApp, in: cfg) {
            autoSwitched = true
            return p.id == current ? nil : p.id
        }
        if autoSwitched {
            autoSwitched = false
            let back = cfg.profileIndex(cfg.defaultProfile) != nil ? cfg.defaultProfile : 1
            return back == current ? nil : back
        }
        return nil
    }

    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
