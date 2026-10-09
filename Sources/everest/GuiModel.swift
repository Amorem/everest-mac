import AppKit
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview, profiles, lighting, displays, buttons, keyboard, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return tr("section.overview.title")
        case .profiles: return tr("section.profiles.title")
        case .lighting: return tr("lighting.title")
        case .displays: return tr("section.displays.title")
        case .buttons: return tr("section.buttons.title")
        case .keyboard: return tr("section.keyboard.title")
        case .system: return tr("section.system.title")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return tr("section.overview.subtitle")
        case .profiles: return tr("section.profiles.subtitle")
        case .lighting: return tr("section.lighting.subtitle")
        case .displays: return tr("section.displays.subtitle")
        case .buttons: return tr("section.buttons.subtitle")
        case .keyboard: return tr("section.keyboard.subtitle")
        case .system: return tr("section.system.subtitle")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "sparkles"
        case .profiles: return "square.stack.3d.up.fill"
        case .lighting: return "light.max"
        case .displays: return "circle.circle"
        case .buttons: return "square.grid.2x2.fill"
        case .keyboard: return "keyboard"
        case .system: return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return Theme.violet
        case .profiles: return Theme.rose
        case .lighting: return Theme.pink
        case .displays: return Theme.cyan
        case .buttons: return Theme.indigo
        case .keyboard: return Theme.emerald
        case .system: return Theme.amber
        }
    }
}

/// Which colour the shared macOS colour panel is editing.
enum ColorTarget: Equatable {
    case palette(Int)
    case firmware(Int)
    case brush
}

/// Receives live changes from the shared macOS colour panel.
@MainActor
final class ColorEditTarget: NSObject {
    var onChange: ((NSColor) -> Void)?
    @objc func colorChanged(_ sender: NSColorPanel) { onChange?(sender.color) }
}

enum FirmwareBlock: Equatable {
    case unsupported(String)
    case unreadable

    /// nil when the keyboard runs the tested firmware.
    init?(version: UInt8?) {
        guard let version else { self = .unreadable; return }
        if Keyboard.isSupported(firmware: version) { return nil }
        self = .unsupported(String(format: "%x", version))
    }
}

@MainActor
final class EverestModel: ObservableObject {
    @Published var config: Config
    @Published var section: Section = .overview
    @Published var status = tr("status.ready")
    @Published var statusIsError = false
    @Published var connected = false
    @Published var attached = "—"
    @Published var dialMode = "—"
    @Published var firmware = "—"
    /// Set when the connected keyboard runs a firmware this app was not
    /// tested with: nothing is written to it and the window says why.
    @Published var firmwareBlock: FirmwareBlock?
    @Published var progress: Double? = nil
    @Published var daemonRunning = false
    /// Layout the keyboard reports (nil until it has been read).
    @Published var detectedLayout: KeyboardLayout?
    /// What the app draws and animates: the manual choice, else the detected
    /// layout, else the last one seen, else US (like Base Camp).
    var layout: KeyboardLayout { config.layoutOverride ?? detectedLayout ?? config.lastLayout ?? .us }
    /// Accessibility is what lets key-combo and typed-text actions reach
    /// other apps; without it macOS drops them silently.
    @Published var accessibilityOK = ActionRunner.accessibilityGranted()

    // Lighting
    @Published var source: LightingConfig.Source
    @Published var firmwareLighting: FirmwareLighting
    @Published var effect: LedEffect
    @Published var playing = false
    @Published var painting = false
    @Published var brush = RGB(r: 255, g: 255, b: 255)
    @Published var previewMain = [RGB](repeating: .black, count: LedLayout.mainLedCount)
    @Published var previewSide = [RGB](repeating: .black, count: LedLayout.sideLedCount)

    let colorTarget = ColorEditTarget()
    private var editing: ColorTarget?
    private var player: LedPlayer?
    private var previewTimer: Timer?
    private var daemonProcess: Process?
    private var pendingApply: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private let device = DispatchQueue(label: "everest.device", qos: .userInitiated)

    init() {
        let cfg = Config.load()
        config = cfg
        L10n.use(cfg.language.flatMap(Language.init(rawValue:)))
        status = tr("status.ready")
        LedLayout.use(cfg.layoutOverride ?? cfg.lastLayout ?? .us)
        let lighting = cfg.lighting ?? LightingConfig()
        source = lighting.source
        firmwareLighting = lighting.firmware
        effect = lighting.mac
        colorTarget.onChange = { [weak self] ns in
            guard let self, let target = self.editing else { return }
            let c = ns.usingColorSpace(.sRGB) ?? .white
            let rgb = RGB(r: UInt8(max(0, min(255, c.redComponent * 255))),
                          g: UInt8(max(0, min(255, c.greenComponent * 255))),
                          b: UInt8(max(0, min(255, c.blueComponent * 255))))
            self.setColor(rgb, for: target)
        }
    }

    // MARK: - Lifecycle

    func start() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickPreview() }
        }
        refreshDevice()
        if !config.keepFlashActions {
            device.async { [weak self] in
                guard self != nil, let kb = try? Keyboard() else { return }
                defer { kb.close() }
                kb.wake()
                kb.neutraliseKeyActions()
            }
        }
        if config.daemonEnabled { startDaemon() }
        profileTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollProfile() }
        }
        pollProfile()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.frontAppChanged(app?.bundleIdentifier) }
        }
    }

    // MARK: - Profiles

    private var profileTimer: Timer?
    private let switcher = AutoSwitcher()

    var profiles: [ProfileConfig] { config.profiles }
    var activeProfile: ProfileConfig? { config.profileIndex(config.selectedProfile).map { config.profiles[$0] } }

    /// Follow the keyboard: the dial's Profile menu changes it too.
    private func pollProfile() {
        accessibilityOK = ActionRunner.accessibilityGranted()
        // Stay off the channel during a picture upload — ours, or one started
        // from the command line (it leaves the FlashBusy marker).
        guard keyUpload == nil, !FlashBusy.active else { return }
        device.async { [weak self] in
            guard let kb = try? Keyboard(allowUnsupported: true) else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.firmwareBlock = nil
                    self?.attached = tr("device.notConnected")
                }
                return
            }
            defer { kb.close() }
            // The periodic check also notices a keyboard swapped or updated
            // while the app runs.
            if let block = FirmwareBlock(version: kb.firmwareVersion) {
                let fw = kb.firmwareVersion.map { String(format: "%x", $0) } ?? "—"
                DispatchQueue.main.async {
                    guard let self, self.confirmBlock(block) else { return }
                    self.connected = true
                    self.firmware = fw
                    self.attached = tr("device.blocked")
                    self.firmwareBlock = block
                    self.enforceFirmwareBlock()
                }
                return
            }
            let p = Int(kb.currentProfile())
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = true
                if self.firmwareBlock != nil {
                    self.firmwareBlock = nil
                    self.unreadableStreak = 0
                    self.refreshDevice()
                }
                if p != self.config.selectedProfile {
                    if self.config.profileIndex(p) == nil {
                        // A hardware profile the app has not named yet.
                        self.config.profiles.append(self.newProfile(id: p))
                        self.config.profiles.sort { $0.id < $1.id }
                    }
                    self.load(profile: p)
                    self.report(tr("status.profileFromKeyboard", self.activeProfile?.title ?? "\(p)"))
                }
            }
        }
    }

    private func frontAppChanged(_ bundleID: String?) {
        if let target = switcher.update(frontApp: bundleID, current: config.selectedProfile, config: config) {
            switchProfile(to: target, byFrontApp: true)
        }
    }

    /// Show a profile in the app (lighting state, buttons) without touching
    /// the keyboard.
    private func load(profile id: Int) {
        pendingSave?.cancel()
        persistLighting()
        stopPlayer()
        config.selectedProfile = id
        let lighting = config.lighting ?? LightingConfig()
        source = lighting.source
        firmwareLighting = lighting.firmware
        effect = lighting.mac
        painting = false
        config.save()
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

    private func newProfile(id: Int) -> ProfileConfig {
        var p = ProfileConfig(id: id, name: tr("profile.defaultName", id))
        p.color = ProfileConfig.palette[(id - 1) % ProfileConfig.palette.count]
        return p
    }

    var canAddProfile: Bool { config.profiles.count < ProfileSwitch.maxProfiles }

    func addProfile() {
        guard let id = (1...ProfileSwitch.maxProfiles).first(where: { config.profileIndex($0) == nil }) else { return }
        config.profiles.append(newProfile(id: id))
        config.profiles.sort { $0.id < $1.id }
        config.save()
        switchProfile(to: id)
    }

    func updateProfile(_ id: Int, _ mutate: (inout ProfileConfig) -> Void) {
        guard let i = config.profileIndex(id) else { return }
        mutate(&config.profiles[i])
        config.save()
    }

    func deleteProfile(_ id: Int) {
        guard config.profiles.count > 1, let i = config.profileIndex(id) else { return }
        let wasActive = id == config.selectedProfile
        config.profiles.remove(at: i)
        if config.defaultProfile == id { config.defaultProfile = config.profiles[0].id }
        config.save()
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

    private func tickPreview() {
        let frame: LedRenderer.Frame
        let t = Date().timeIntervalSinceReferenceDate
        if let player {
            frame = player.snapshot()
        } else if source == .firmware {
            frame = LedRenderer.render(firmwareLighting, time: t)
        } else {
            frame = LedRenderer.render(effect, time: t)
        }
        previewMain = frame.main
        previewSide = frame.side
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

    // MARK: - Status

    func report(_ message: String, error: Bool = false) {
        status = message
        statusIsError = error
    }

    private var unreadableStreak = 0

    /// A wrong version is acted on at once; a *missing* answer only when it
    /// happens twice in a row (one lost reply on a busy channel must not
    /// flash the block screen). Writes stay refused either way.
    private func confirmBlock(_ block: FirmwareBlock) -> Bool {
        guard block == .unreadable else { unreadableStreak = 0; return true }
        unreadableStreak += 1
        return unreadableStreak >= 2 || firmwareBlock != nil
    }

    /// True when the D1–D4 listener is really serving the keys: its process
    /// idles while the keyboard is refused.
    var daemonActive: Bool { daemonRunning && firmwareBlock == nil }

    /// A keyboard on an untested firmware is left strictly alone: the Mac
    /// effects player and the daemon refuse to open it themselves (see
    /// `Keyboard.init`), so all that is left is to say so.
    func enforceFirmwareBlock() {
        guard let block = firmwareBlock else { return }
        switch block {
        case .unsupported(let v):
            report(tr("firmware.status.unsupported", v, String(format: "%x", Keyboard.supportedFirmware)), error: true)
        case .unreadable:
            report(tr("firmware.status.unreadable"), error: true)
        }
    }

    // MARK: - Device access

    /// Run a short device session on the serial device queue.
    func runDevice(_ label: String, _ body: @escaping (Keyboard) -> String?) {
        report("\(label)…")
        device.async { [weak self] in
            guard let kb = try? Keyboard() else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.report(tr("device.keyboardUnavailable"), error: true)
                }
                return
            }
            defer { kb.close() }
            kb.wake()
            let message = body(kb)
            DispatchQueue.main.async {
                if let message { self?.report(message) }
                self?.refreshDevice()
            }
        }
    }

    func refreshDevice() {
        device.async { [weak self] in
            // Read-only open: the firmware check below decides whether
            // anything else may talk to the keyboard.
            guard let kb = try? Keyboard(allowUnsupported: true) else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.firmwareBlock = nil
                    self?.attached = tr("device.notConnected")
                }
                return
            }
            let version = kb.firmwareVersion
            // FWInfo.fwVer is BCD-like: 0x57 is firmware 57, 0x39 is 39.
            let fw = version.map { String(format: "%x", $0) } ?? "—"
            if let block = FirmwareBlock(version: version) {
                kb.close()
                DispatchQueue.main.async {
                    guard let self, self.confirmBlock(block) else { return }
                    self.connected = true
                    self.firmware = fw
                    self.attached = tr("device.blocked")
                    self.firmwareBlock = block
                    self.enforceFirmwareBlock()
                }
                return
            }
            let layoutCode = kb.layoutCode
            let state = kb.state()
            kb.close()
            var mode = "—"
            if let s = state {
                mode = Proto.MainMode.allCases.first(where: { $0.menuByte == s.modeByte })?.rawValue ?? "?"
            }
            let summary: String = {
                guard let s = state else { return tr("device.everestMax") }
                switch (s.mmDockPlugged, s.numpadPlugged) {
                case (true, true): return tr("device.full")
                case (true, false): return tr("device.withDock")
                case (false, true): return tr("device.withNumpad")
                case (false, false): return tr("device.core")
                }
            }()
            DispatchQueue.main.async {
                self?.connected = true
                self?.attached = summary
                if let code = layoutCode {
                    let detected = KeyboardLayout(firmwareCode: code)
                    if self?.detectedLayout != detected {
                        self?.detectedLayout = detected
                        self?.config.lastLayout = detected
                        self?.config.save()
                    }
                    self?.applyLayout()
                }
                self?.dialMode = mode
                self?.firmware = fw
                self?.firmwareBlock = nil
                if Proto.MainMode(rawValue: mode) != nil { self?.config.mainDisplayMode = mode }
            }
        }
    }

    // MARK: - Layout

    /// Make the drawing and the effects follow the current layout.
    func applyLayout() {
        objectWillChange.send()
        LedLayout.use(layout)
    }

    /// Force a layout, or nil to follow the keyboard.
    func setLayoutOverride(_ l: KeyboardLayout?) {
        config.layoutOverride = l
        config.save()
        applyLayout()
        report(l.map { tr("status.layoutForced", $0.title) } ?? tr("status.layoutAuto"))
    }

    // MARK: - Language

    /// The language the user picked, nil = follow the system.
    var language: Language? { config.language.flatMap { Language(rawValue: $0) } }

    /// Switch the interface language now: the views are rebuilt (see
    /// `RootView`), the menu-bar menu is rebuilt each time it opens, and the
    /// status line is reset so no stale message stays in the old language.
    func setLanguage(_ language: Language?) {
        L10n.use(language)
        config.language = language?.rawValue
        config.save()
        if firmwareBlock != nil { enforceFirmwareBlock() } else { report(tr("status.ready")) }
        refreshDevice()
    }

    // MARK: - Config

    func saveConfig() {
        config.save()
        report(tr("status.configSaved"))
    }

    func setButton(_ index: Int, name: String? = nil, type: String? = nil, value: String? = nil, iconPath: String? = nil) {
        guard index < config.buttons.count else { return }
        if let name { config.buttons[index].name = name }
        if let type { config.buttons[index].action.type = type }
        if let value { config.buttons[index].action.value = value }
        if let iconPath { config.buttons[index].iconPath = iconPath }
        config.save()
    }

    /// What each display key shows in the app — the image being sent while
    /// an upload runs, so the change is visible straight away.
    var displayImages: [NSImage?] {
        (0..<4).map { i in
            if let u = keyUpload, u.button == i { return u.preview }
            // No custom image: the key shows its factory picture.
            return config.buttons[i].iconPath.flatMap { NSImage(contentsOfFile: $0) } ?? FactoryIcons.image(i)
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

    @Published var keyUpload: KeyUpload?
    /// True while any operation on the display keys is running.
    var keysBusy: Bool { keyUpload != nil }

    func uploadIcon(button: Int, url: URL) {
        guard keyUpload == nil else {
            report(tr("status.uploadBusyAlready", keyUpload!.button + 1), error: true)
            return
        }
        keyUpload = KeyUpload(button: button, preview: NSImage(contentsOf: url))
        progress = 0
        report(tr("status.uploadStarted", button + 1))
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
                    self?.setButton(button, iconPath: url.path)
                    self?.progress = nil
                    self?.keyUpload?.progress = 1
                    self?.keyUpload?.finished = true
                    self?.report(tr("status.iconSent", button + 1, seconds))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.keyUpload = nil }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.progress = nil
                    self?.keyUpload = nil
                    self?.report(tr("status.uploadFailedKey", button + 1, error.localizedDescription), error: true)
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
        config.save()
        uploadIcon(button: button, url: url)
    }

    /// App: its icon on the key, and the key opens / brings it forward.
    func assignApp(_ app: URL, to button: Int) {
        guard let icon = IconFactory.render(app: app) else {
            report(tr("status.appIconUnreadable"), error: true)
            return
        }
        config.buttons[button].action = ButtonAction(type: "app", value: app.path)
        config.buttons[button].name = FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
        config.save()
        uploadIcon(button: button, url: icon)
    }

    /// Back to what D1–D4 do out of the box: factory picture on the key, and
    /// the default action, name included.
    func restoreFactory(_ button: Int) {
        config.buttons[button] = FactoryKeys.button(button)
        config.save()
        resetButtonIcon(button)
    }

    func resetButtonIcon(_ button: Int) {
        guard keyUpload == nil else {
            report(tr("status.uploadBusy", keyUpload!.button + 1), error: true)
            return
        }
        runDevice(tr("reset.title")) { kb in
            let slot = Int(kb.currentProfile())
            try? kb.transport.write(Proto.resetNumpadPics(1 << UInt8(button), slot: slot))
            _ = kb.transport.read(timeout: 0.5)
            // The reset also brings back the factory action of the key.
            kb.neutraliseKeyActions()
            return tr("status.factoryIconRestored", button + 1)
        }
        config.buttons[button].iconPath = nil
        config.save()
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
                    self?.config.save()
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
        config.save()
        runDevice(tr("status.displayLabel")) { kb in
            kb.setMainMode(mode)
            return tr("status.dialMode", label)
        }
    }

    func syncClock() {
        let style: UInt8 = config.clockStyle == "digital" ? 0x01 : 0x00
        let twelve = config.clockFormat == "12h"
        config.save()
        runDevice(tr("mode.clock")) { kb in
            kb.setTime(style: style, twelveHour: twelve)
            return tr("status.clockSynced")
        }
    }

    // MARK: - Colours

    func editColor(_ target: ColorTarget) {
        editing = target
        let c: RGB
        switch target {
        case .palette(let i): c = i < effect.palette.count ? effect.palette[i] : .white
        case .firmware(let i): c = firmwareLighting.color(i)
        case .brush: c = brush
        }
        let panel = NSColorPanel.shared
        panel.setTarget(colorTarget)
        panel.setAction(#selector(ColorEditTarget.colorChanged(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                              blue: CGFloat(c.b) / 255, alpha: 1)
        panel.makeKeyAndOrderFront(nil)
    }

    private func setColor(_ rgb: RGB, for target: ColorTarget) {
        switch target {
        case .palette(let i):
            guard i < effect.palette.count else { return }
            updateEffect { $0.palette[i] = rgb }
        case .firmware(let i):
            updateFirmware { fw in
                while fw.colors.count <= i { fw.colors.append(.white) }
                fw.colors[i] = rgb
            }
        case .brush:
            brush = rgb
        }
    }

    func addPaletteColor() {
        let vivid = ["ff2d95", "ffb300", "3dffb0", "00b3ff", "a25bff", "ff5a36", "f5ff3d", "ffffff"]
        let next = RGB(hex: vivid[effect.palette.count % vivid.count]) ?? .white
        guard effect.palette.count < 8 else { return }
        updateEffect { $0.palette.append(next) }
        editColor(.palette(effect.palette.count - 1))
    }

    func removePaletteColor(_ i: Int) {
        guard effect.palette.count > 1, i < effect.palette.count else { return }
        updateEffect { $0.palette.remove(at: i) }
    }

    // MARK: - Firmware lighting

    /// Mutate the built-in effect and push it after a short pause, the way
    /// Base Camp applies and saves on every change.
    func updateFirmware(_ mutate: (inout FirmwareLighting) -> Void) {
        mutate(&firmwareLighting)
        if source == .firmware { scheduleFirmwareApply() }
    }

    func selectFirmware(_ effect: FirmwareLighting.Effect) {
        source = .firmware
        stopPlayer()
        firmwareLighting.effect = effect
        if !effect.modes.contains(firmwareLighting.mode), let first = effect.modes.first {
            firmwareLighting.mode = effect == .wave || effect == .breathing ? .rainbow : first
        }
        scheduleFirmwareApply(delay: 0.05)
    }

    func applyFirmwareNow() {
        source = .firmware
        stopPlayer()
        scheduleFirmwareApply(delay: 0)
    }

    private func scheduleFirmwareApply(delay: TimeInterval = 0.35) {
        pendingApply?.cancel()
        let fw = firmwareLighting
        let work = DispatchWorkItem { [weak self] in
            guard let kb = try? Keyboard() else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.report(tr("status.previewOnly"), error: true)
                }
                return
            }
            defer { kb.close() }
            kb.wake()
            kb.apply(fw, save: true)
            DispatchQueue.main.async {
                self?.connected = true
                self?.report(tr("status.effectApplied", fw.effect.title))
            }
        }
        pendingApply = work
        device.asyncAfter(deadline: .now() + delay, execute: work)
        persistLightingSoon()
    }

    // MARK: - Mac effects

    func updateEffect(_ mutate: (inout LedEffect) -> Void) {
        mutate(&effect)
        player?.update(effect)
        persistLightingSoon()
    }

    /// Picking a Mac effect switches the board to it straight away.
    func selectEffect(_ kind: LedEffect.Kind) {
        source = .mac
        effect.kind = kind
        if kind != .solid { painting = false }
        if let player {
            player.update(effect)
        } else {
            startPlayer()
        }
        report(tr("status.effectRunningKeyboard", kind.title))
        persistLightingSoon()
    }

    func applyPalettePreset(_ colors: [RGB]) {
        updateEffect { $0.palette = colors }
    }

    func paintKey(_ index: Int) {
        guard effect.perKey[index] != brush else { return }
        if effect.perKey.isEmpty {
            // Start from the current solid colour so unpainted keys stay lit.
            let base = effect.palette.first ?? .white
            var map: [Int: RGB] = [:]
            for i in 0..<LedLayout.mainLedCount where LedLayout.positionTable[i] != nil { map[i] = base }
            effect.perKey = map
        }
        updateEffect { $0.perKey[index] = brush }
    }

    func clearPainting() {
        updateEffect { $0.perKey = [:] }
    }

    func startPlayer() {
        guard player == nil else { return }
        source = .mac
        pendingApply?.cancel()
        let p = LedPlayer(effect: effect)
        p.onConnection = { [weak self] up in
            DispatchQueue.main.async {
                // A firmware block is reported by its own screen, not as "gone".
                guard let self, self.firmwareBlock == nil else { return }
                self.connected = up
                self.report(up ? tr("status.keyboardConnected") : tr("status.keyboardGone"),
                            error: !up)
            }
        }
        player = p
        p.start(fps: 30)
        playing = true
    }

    func stopPlayer() {
        player?.stop()
        player = nil
        playing = false
    }

    func togglePlayback() {
        if playing {
            stopPlayer()
            report(tr("status.animationPaused"))
        } else {
            startPlayer()
            report(tr("status.effectRunningKeyboard", effect.kind.title))
        }
    }

    /// Show the current design once and keep it in the custom slot's flash,
    /// so it survives without the app (static designs only).
    func saveStaticToKeyboard() {
        stopPlayer()
        let e = effect
        runDevice(tr("status.saving")) { kb in
            LedPlayer.applyOnce(e, keyboard: kb)
            kb.send(FirmwareLighting.saveFlash(slot: 6), wait: 0.5)
            return tr("status.frozen")
        }
    }

    // MARK: - Persistence

    private func persistLightingSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistLighting() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func persistLighting() {
        config.lighting = LightingConfig(source: source, firmware: firmwareLighting, mac: effect)
        config.save()
    }

    // MARK: - Daemon & recovery

    /// Start or stop the D1–D4 listener, and remember the choice: while it is
    /// on, the app starts it at launch and restarts it if it ever dies.
    func toggleDaemon() {
        config.daemonEnabled = daemonProcess == nil
        config.save()
        if config.daemonEnabled { startDaemon() } else { stopDaemon() }
    }

    private var quitting = false

    func startDaemon() {
        guard daemonProcess == nil else { return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["listen", "--no-prompt"]
        // Keep the daemon's output: it says which key fired what, and warns
        // when macOS refuses to post key events.
        let logURL = Config.directory.appendingPathComponent("daemon.log")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: logURL)   // keep it small
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.daemonProcess === proc else { return }
                self.daemonProcess = nil
                self.daemonRunning = false
                // Unexpected end: bring it back unless the user switched it off.
                if self.config.daemonEnabled && !self.quitting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.config.daemonEnabled, !self.quitting else { return }
                        self.startDaemon()
                    }
                }
            }
        }
        do {
            try p.run()
            daemonProcess = p
            daemonRunning = true
            report(tr("status.daemonOn"))
        } catch {
            report(tr("status.daemonStartFailed", error.localizedDescription), error: true)
        }
    }

    func stopDaemon() {
        let p = daemonProcess
        daemonProcess = nil
        daemonRunning = false
        p?.terminate()
        report(tr("status.daemonOff"))
    }

    // MARK: - Launch at login

    @Published var launchAtLogin = LoginItem.enabled
    @Published var loginItemNote: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItemNote = LoginItem.status == .requiresApproval
                ? tr("status.loginApproval") : nil
        } catch {
            loginItemNote = tr("status.changeFailed", error.localizedDescription)
        }
        launchAtLogin = LoginItem.enabled
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func recover() {
        runDevice(tr("status.recovering")) { kb in
            kb.recover()
            return tr("status.recoverySent")
        }
    }

    func clearFlashActions() {
        runDevice(tr("status.cleaning")) { kb in
            kb.neutraliseKeyActions()
            return tr("status.leftoversCleared")
        }
    }
}

// MARK: - Display names

extension FirmwareLighting.Effect {
    var title: String {
        switch self {
        case .staticColor: return tr("fx.static")
        case .wave: return tr("fx.wave")
        case .tornado: return tr("fx.tornado")
        case .breathing: return tr("fx.breathing")
        case .reactive: return tr("fx.reactive")
        case .matrix: return tr("fx.matrix")
        case .yeti: return tr("fx.yeti")
        case .off: return tr("fx.off")
        }
    }

    var icon: String {
        switch self {
        case .staticColor: return "circle.fill"
        case .wave: return "water.waves"
        case .tornado: return "tornado"
        case .breathing: return "wind"
        case .reactive: return "hand.tap.fill"
        case .matrix: return "cloud.rain.fill"
        case .yeti: return "dot.radiowaves.left.and.right"
        case .off: return "power"
        }
    }

    var blurb: String {
        switch self {
        case .staticColor: return tr("fx.static.desc")
        case .wave: return tr("fx.wave.desc")
        case .tornado: return tr("fx.tornado.desc")
        case .breathing: return tr("fx.breathing.desc")
        case .reactive: return tr("fx.reactive.desc")
        case .matrix: return tr("fx.matrix.desc")
        case .yeti: return tr("fx.yeti.desc")
        case .off: return tr("fx.off.desc")
        }
    }
}

extension FirmwareLighting.ColorMode {
    var title: String {
        switch self {
        case .single: return tr("colormode.single")
        case .dual: return tr("colormode.dual")
        case .quad: return tr("colormode.quad")
        case .rainbow: return tr("colormode.rainbow")
        case .withBackground: return tr("colormode.withBackground")
        }
    }
}

extension LedEffect.Kind {
    var title: String {
        switch self {
        case .solid: return tr("macfx.solid")
        case .gradient: return tr("macfx.gradient")
        case .rainbow: return tr("macfx.spectrum")
        case .wave: return tr("macfx.waves")
        case .breathe: return tr("fx.breathing")
        case .aurora: return tr("macfx.aurora")
        case .plasma: return tr("macfx.plasma")
        case .vortex: return tr("macfx.spiral")
        case .ripple: return tr("macfx.ripples")
        case .fire: return tr("macfx.fire")
        case .rain: return tr("macfx.rain")
        case .starlight: return tr("macfx.stars")
        case .scanner: return tr("macfx.scanner")
        case .equalizer: return tr("macfx.equalizer")
        case .off: return tr("fx.off")
        }
    }

    var icon: String {
        switch self {
        case .solid: return "paintbrush.pointed.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .rainbow: return "rainbow"
        case .wave: return "water.waves"
        case .breathe: return "wind"
        case .aurora: return "sparkles"
        case .plasma: return "drop.halffull"
        case .vortex: return "hurricane"
        case .ripple: return "dot.radiowaves.left.and.right"
        case .fire: return "flame.fill"
        case .rain: return "cloud.drizzle.fill"
        case .starlight: return "star.fill"
        case .scanner: return "arrow.left.and.right"
        case .equalizer: return "chart.bar.fill"
        case .off: return "power"
        }
    }
}

struct PalettePreset: Identifiable {
    let name: String
    let colors: [RGB]
    var id: String { name }

    static var all: [PalettePreset] { [
        PalettePreset(name: tr("macfx.aurora"), colors: ["00ffaa", "008cff", "aa3cff"]),
        PalettePreset(name: tr("palette.neon"), colors: ["ff2d95", "7a5cff", "00e5ff"]),
        PalettePreset(name: tr("palette.sunset"), colors: ["ff3d3d", "ff8a00", "ffd23f", "ff2d95"]),
        PalettePreset(name: tr("palette.ocean"), colors: ["00e0ff", "0066ff", "00ffc8"]),
        PalettePreset(name: tr("palette.cyberpunk"), colors: ["fcee0a", "ff003c", "00f0ff"]),
        PalettePreset(name: tr("palette.forest"), colors: ["b6ff3d", "00c46a", "00806b"]),
        PalettePreset(name: tr("palette.ember"), colors: ["ff1e00", "ff7a00", "ffd000"]),
        PalettePreset(name: tr("palette.ice"), colors: ["ffffff", "8fe3ff", "2d6cff"]),
        PalettePreset(name: tr("palette.vapor"), colors: ["ff71ce", "01cdfe", "05ffa1", "b967ff"]),
    ] }

    init(name: String, colors: [String]) {
        self.name = name
        self.colors = colors.compactMap { RGB(hex: $0) }
    }
}
