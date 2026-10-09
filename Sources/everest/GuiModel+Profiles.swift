import AppKit
import SwiftUI

// Profiles: switching, editing, linked apps, following the keyboard.
extension EverestModel {
    // MARK: - Profiles


    var profiles: [ProfileConfig] { config.profiles }
    var activeProfile: ProfileConfig? { config.profileIndex(config.selectedProfile).map { config.profiles[$0] } }


    func frontAppChanged(_ bundleID: String?) {
        if let target = switcher.update(frontApp: bundleID, current: config.selectedProfile, config: config) {
            switchProfile(to: target, byFrontApp: true)
        }
    }

    /// Show a profile in the app (lighting state, buttons) without touching
    /// the keyboard.
    func load(profile id: Int) {
        pendingSave?.cancel()
        persistLighting()
        stopPlayer()
        config.selectedProfile = id
        let lighting = config.lighting ?? LightingConfig()
        source = lighting.source
        firmwareLighting = lighting.firmware
        effect = lighting.mac
        painting = false
        persist()
        if config.lighting?.source == .mac { startPlayer() }
    }

    func switchProfile(to id: Int, byFrontApp: Bool = false) {
        guard let i = config.profileIndex(id) else { return }
        load(profile: id)
        let p = config.profiles[i]
        if let raw = p.dialMode { config.mainDisplayMode = raw }
        device.async { [weak self] in
            guard let kb = try? Keyboard() else { return }
            defer { kb.close() }
            kb.wake()
            ProfileSwitch.activate(p, keyboard: kb)
            if self?.config.keepFlashActions == false { kb.neutraliseKeyActions() }
            DispatchQueue.main.async {
                self?.report(tr(byFrontApp ? "status.profileActivatedFrontApp" : "status.profileActivated", p.title))
                self?.refreshDevice()
            }
        }
    }

    func newProfile(id: Int) -> ProfileConfig {
        var p = ProfileConfig(id: id, name: tr("profile.defaultName", id))
        p.color = ProfileConfig.palette[(id - 1) % ProfileConfig.palette.count]
        return p
    }

    var canAddProfile: Bool { config.profiles.count < ProfileSwitch.maxProfiles }

    func addProfile() {
        guard let id = (1...ProfileSwitch.maxProfiles).first(where: { config.profileIndex($0) == nil }) else { return }
        config.profiles.append(newProfile(id: id))
        config.profiles.sort { $0.id < $1.id }
        persist()
        switchProfile(to: id)
    }

    func updateProfile(_ id: Int, _ mutate: (inout ProfileConfig) -> Void) {
        guard let i = config.profileIndex(id) else { return }
        mutate(&config.profiles[i])
        persist()
    }

    func deleteProfile(_ id: Int) {
        guard config.profiles.count > 1, let i = config.profileIndex(id) else { return }
        let wasActive = id == config.selectedProfile
        config.profiles.remove(at: i)
        if config.defaultProfile == id { config.defaultProfile = config.profiles[0].id }
        persist()
        if wasActive { switchProfile(to: config.defaultProfile) }
        report(tr("status.profileRemoved", id))
    }

    func linkApp(_ url: URL, to id: Int) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            report(tr("status.appNoId"), error: true)
            return
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        // An app belongs to one profile at a time.
        for i in config.profiles.indices { config.profiles[i].apps.removeAll { $0.bundleID == bundleID } }
        updateProfile(id) { $0.apps.append(LinkedApp(bundleID: bundleID, name: name, path: url.path)) }
    }

    func unlinkApp(_ bundleID: String, from id: Int) {
        updateProfile(id) { $0.apps.removeAll { $0.bundleID == bundleID } }
    }

    func tickPreview() {
        // Nothing to draw into: the window is closed (menu-bar only) or
        // hidden behind others.
        guard NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) && $0.contentView is NSHostingView<RootView> }) else { return }
        let frame: LedRenderer.Frame
        let t = Date().timeIntervalSinceReferenceDate
        if let player {
            frame = player.snapshot()
        } else if source == .firmware {
            frame = LedRenderer.render(firmwareLighting, time: t)
        } else {
            frame = LedRenderer.render(effect, time: t)
        }
        // A still effect gives the same frame every time: publishing it would
        // still re-evaluate every view that watches the model.
        if frame.main != previewMain { previewMain = frame.main }
        if frame.side != previewSide { previewSide = frame.side }
    }

    func stopEverything() {
        quitting = true
        player?.stop()
        player = nil
        playing = false
        daemonProcess?.terminate()
        daemonProcess = nil
        persistLighting()
    }
}
