import AppKit
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview, profiles, lighting, displays, buttons, displaypad, keyboard, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return tr("section.overview.title")
        case .profiles: return tr("section.profiles.title")
        case .lighting: return tr("lighting.title")
        case .displays: return tr("section.displays.title")
        case .buttons: return tr("section.buttons.title")
        case .displaypad: return tr("section.displaypad.title")
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
        case .displaypad: return tr("section.displaypad.subtitle")
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
        case .displaypad: return "rectangle.split.3x1.fill"
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
        case .displaypad: return Theme.sky
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
    /// The DisplayPad is plugged in (USB presence only; the daemon talks to it).
    @Published var padConnected = DisplayPad.isPresent
    /// What the daemon reports about the pad (nil while it is not running).
    @Published var padState: PadState?
    /// Values shown on live pad keys in the app (sampled every 2 s while
    /// a key of the selected profile shows one).
    @Published var liveSample = MetricsSample()
    /// Night mode is on (the state file, checked with the device status).
    @Published var nightMode = NightMode.active
    /// Mac-rendered lighting paused for the night, to resume in the morning.
    var playerPausedForNight = false
    /// The DisplayPad gets its own queue: a pad that does not answer must not
    /// hold up the keyboard.
    let padQueue = DispatchQueue(label: "everest.pad", qos: .userInitiated)
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
    var editing: ColorTarget?
    var player: LedPlayer?
    var previewTimer: Timer?
    var daemonProcess: Process?
    var pendingApply: DispatchWorkItem?
    var pendingSave: DispatchWorkItem?
    var pendingTextSave: DispatchWorkItem?
    /// Date of config.json as this process last read or wrote it.
    var configStamp = Config.fileStamp
    let device = DispatchQueue(label: "everest.device", qos: .userInitiated)

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


    // State used by the extensions in GuiModel+*.swift (stored properties
    // cannot live in an extension).
    var profileTimer: Timer?
    let switcher = AutoSwitcher()
    var unreadableStreak = 0
    /// Restarts of the daemon in a row, for the back-off.
    var daemonRestarts = 0
    @Published var keyUpload: KeyUpload?
    var quitting = false
    @Published var launchAtLogin = LoginItem.enabled
    @Published var loginItemNote: String?

    // MARK: - Lifecycle

    func start() {
        // A profile key tried from the app (Test button) switches here.
        ActionRunner.profileHandler = { [weak self] value in
            DispatchQueue.main.async {
                guard let self, let target = ProfileRequest.resolve(value, current: self.config.selectedProfile, config: self.config)
                else { return }
                self.switchProfile(to: target)
            }
        }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickPreview() }
        }
        refreshDevice()
        // The daemon neutralises the keys itself when it connects.
        if !config.keepFlashActions && !config.daemonEnabled {
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

    /// Follow the keyboard: the dial's Profile menu changes it too.
    /// The daemon switches the keyboard and pad off; the app pauses the
    /// lighting it renders itself, and resumes it when night mode ends.
    func followNightMode() {
        let night = NightMode.active
        if night != nightMode { nightMode = night }
        if night, player != nil {
            stopPlayer()
            playerPausedForNight = true
        } else if !night, playerPausedForNight {
            playerPausedForNight = false
            if source == .mac { startPlayer() }
        }
    }

    func pollProfile() {
        accessibilityOK = ActionRunner.accessibilityGranted()
        padConnected = DisplayPad.isPresent
        padState = daemonRunning && padConnected ? PadState.read() : nil
        if config.padButtons.contains(where: { $0.live != nil }) { liveSample = Metrics.latest(maxAge: 1.5) }
        reloadConfigIfChanged()
        followNightMode()
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

    // MARK: - Status

    func report(_ message: String, error: Bool = false) {
        status = message
        statusIsError = error
    }


    /// A wrong version is acted on at once; a *missing* answer only when it
    /// happens twice in a row (one lost reply on a busy channel must not
    /// flash the block screen). Writes stay refused either way.
    func confirmBlock(_ block: FirmwareBlock) -> Bool {
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

}
