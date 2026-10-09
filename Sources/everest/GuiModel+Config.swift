import AppKit
import SwiftUI

// Saving the configuration and the D1–D4 / dial pictures.
extension EverestModel {
    // MARK: - Config

    func saveConfig() {
        persist()
        report(tr("status.configSaved"))
    }

    /// Save, and remember the file's date so our own write is not mistaken
    /// for an outside change.
    func persist() {
        pendingTextSave?.cancel()
        pendingTextSave = nil
        config.save()
        configStamp = Config.fileStamp
    }

    /// For text fields: save once typing pauses, not on every keystroke (the
    /// daemon reloads the file each time it changes).
    func persistSoon() {
        pendingTextSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persist() }
        }
        pendingTextSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The file was changed by someone else (the daemon, `everest`, a text
    /// editor): take their version instead of overwriting it on the next save.
    func reloadConfigIfChanged() {
        let stamp = Config.fileStamp
        guard stamp != configStamp, pendingTextSave == nil, pendingSave == nil else { return }
        configStamp = stamp
        guard stamp != nil else { return }
        let fresh = Config.load()
        let lighting = fresh.lighting ?? LightingConfig()
        let lightingChanged = fresh.selectedProfile != config.selectedProfile
            || lighting.source != source
        config = fresh
        L10n.use(fresh.language.flatMap(Language.init(rawValue:)))
        if lightingChanged {
            stopPlayer()
            source = lighting.source
            firmwareLighting = lighting.firmware
            effect = lighting.mac
            if source == .mac { startPlayer() }
        }
        report(tr("status.configReloaded"))
    }

    func setButton(_ index: Int, name: String? = nil, type: ActionKind? = nil, value: String? = nil, iconPath: String? = nil) {
        guard index < config.buttons.count else { return }
        if let name { config.buttons[index].name = name }
        if let type { config.buttons[index].action.type = type }
        if let value { config.buttons[index].action.value = value }
        if let iconPath { config.buttons[index].iconPath = iconPath }
        if type == nil && iconPath == nil { persistSoon() } else { persist() }
    }

    /// What each display key shows in the app — the image being sent while
    /// an upload runs, so the change is visible straight away.
    var displayImages: [NSImage?] {
        (0..<4).map { i in
            if let u = keyUpload, u.button == i { return u.preview }
            // No custom image: the key shows its factory picture.
            return config.buttons[i].iconPath.flatMap(ImageFileCache.image) ?? FactoryIcons.image(i)
        }
    }

    var dialImage: NSImage? { config.dialImagePath.flatMap { NSImage(contentsOfFile: $0) } }

    // MARK: - Display-key images

    /// A running transfer to one display key.
    struct KeyUpload {
        let button: Int
        let preview: NSImage?
        let started = Date()
        var progress: Double = 0
        var finished = false

        /// Phases match `Keyboard.uploadIcon`'s progress ranges.
        var phase: String {
            if finished { return tr("upload.phase.done") }
            switch Int(progress * 100) {
            case ..<5: return tr("upload.phase.connect")
            case ..<52: return tr("upload.phase.prepare")
            case ..<98: return tr("upload.phase.send")
            default: return tr("upload.phase.finish")
            }
        }
    }

    /// True while any operation on the display keys is running.
    var keysBusy: Bool { keyUpload != nil }

    func uploadIcon(button: Int, url: URL) {
        guard keyUpload == nil else {
            report(tr("status.uploadBusyAlready", "D\(keyUpload!.button + 1)"), error: true)
            return
        }
        keyUpload = KeyUpload(button: button, preview: NSImage(contentsOf: url))
        progress = 0
        report(tr("status.uploadStarted", "D\(button + 1)"))
        device.async { [weak self] in
            let started = Date()
            do {
                let bytes = try ImageTools.rgb565(path: url.path, width: Keyboard.iconW, height: Keyboard.iconH)
                guard let kb = try? Keyboard() else {
                    throw NSError(domain: "everest", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("device.keyboardMissing")])
                }
                defer { kb.close() }
                kb.wake()
                let slot = Int(kb.currentProfile())
                try kb.uploadIcon(button: button, image: bytes, slot: slot) { pct in
                    DispatchQueue.main.async {
                        self?.progress = Double(pct) / 100.0
                        self?.keyUpload?.progress = Double(pct) / 100.0
                    }
                }
                let seconds = Int(Date().timeIntervalSince(started).rounded())
                DispatchQueue.main.async {
                    // The slot is the keyboard profile it went to, even if
                    // another profile was selected meanwhile.
                    if let self, let i = self.config.profileIndex(slot) {
                        self.config.profiles[i].buttons[button].iconPath = url.path
                        self.persist()
                    }
                    self?.progress = nil
                    self?.keyUpload?.progress = 1
                    self?.keyUpload?.finished = true
                    self?.report(tr("status.iconSent", "D\(button + 1)", seconds))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.keyUpload = nil }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.progress = nil
                    self?.keyUpload = nil
                    self?.report(tr("status.uploadFailedKey", "D\(button + 1)", error.localizedDescription), error: true)
                }
            }
        }
    }

    /// Preset: draw its icon, upload it, and (optionally) take its action.
    func applyPreset(_ preset: ButtonPreset, to button: Int, withAction: Bool) {
        guard let url = preset.appURL.flatMap({ IconFactory.render(app: $0) }) ?? IconFactory.render(preset) else {
            report(tr("status.iconDrawFailed"), error: true)
            return
        }
        if withAction, let action = preset.action {
            config.buttons[button].action = action
            config.buttons[button].name = preset.name
        }
        persist()
        uploadIcon(button: button, url: url)
    }

    /// App: its icon on the key, and the key opens / brings it forward.
    func assignApp(_ app: URL, to button: Int) {
        guard let icon = IconFactory.render(app: app) else {
            report(tr("status.appIconUnreadable"), error: true)
            return
        }
        config.buttons[button].action = ButtonAction(type: .app, value: app.path)
        config.buttons[button].name = FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
        persist()
        uploadIcon(button: button, url: icon)
    }

    /// Back to what D1–D4 do out of the box: factory picture on the key, and
    /// the default action, name included.
    func restoreFactory(_ button: Int) {
        config.buttons[button] = FactoryKeys.button(button)
        persist()
        resetButtonIcon(button)
    }

    func resetButtonIcon(_ button: Int) {
        guard keyUpload == nil else {
            report(tr("status.uploadBusy", "D\(keyUpload!.button + 1)"), error: true)
            return
        }
        runDevice(tr("reset.title")) { kb in
            let slot = Int(kb.currentProfile())
            try? kb.transport.write(Proto.resetNumpadPics(1 << UInt8(button), slot: slot))
            _ = kb.transport.read(timeout: 0.5)
            // The reset also brings back the factory action of the key.
            kb.neutraliseKeyActions()
            return tr("status.factoryIconRestored", "D\(button + 1)")
        }
        config.buttons[button].iconPath = nil
        persist()
    }

    func uploadDialImage(url: URL) {
        progress = 0
        report(tr("status.sendingImage"))
        device.async { [weak self] in
            do {
                let bytes = try ImageTools.rgb565(path: url.path, width: Keyboard.mainW, height: Keyboard.mainH)
                guard let kb = try? Keyboard() else {
                    throw NSError(domain: "everest", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("device.keyboardMissing")])
                }
                defer { kb.close() }
                kb.wake()
                try kb.uploadMainDisplay(image: bytes) { pct in
                    DispatchQueue.main.async { self?.progress = Double(pct) / 100.0 }
                }
                DispatchQueue.main.async {
                    self?.config.dialImagePath = url.path
                    self?.persist()
                    self?.progress = nil
                    self?.report(tr("status.dialImageSent"))
                    self?.refreshDevice()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.progress = nil
                    self?.report(tr("status.uploadFailed", error.localizedDescription), error: true)
                }
            }
        }
    }

    func setDialMode(_ mode: Proto.MainMode, label: String) {
        config.mainDisplayMode = mode.rawValue
        persist()
        runDevice(tr("status.displayLabel")) { kb in
            kb.setMainMode(mode)
            return tr("status.dialMode", label)
        }
    }

    func syncClock() {
        let style: UInt8 = config.clockStyle == "digital" ? 0x01 : 0x00
        let twelve = config.clockFormat == "12h"
        persist()
        runDevice(tr("mode.clock")) { kb in
            kb.setTime(style: style, twelveHour: twelve)
            return tr("status.clockSynced")
        }
    }


    // MARK: - Persistence

    func persistLightingSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistLighting() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func persistLighting() {
        pendingSave = nil
        config.lighting = LightingConfig(source: source, firmware: firmwareLighting, mac: effect)
        persist()
    }
}
