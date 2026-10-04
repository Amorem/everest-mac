import AppKit
import Combine

/// A menu item that runs a closure.
final class BlockItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, key: String = "",
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The menu-bar icon: Everest keeps working with the window closed, and the
/// basics — profile, lighting, the D1–D4 listener, login item — are one click
/// away.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: EverestModel
    private let openWindow: (Section?) -> Void
    private let quit: () -> Void
    private var bag = Set<AnyCancellable>()

    init(model: EverestModel, openWindow: @escaping (Section?) -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        self.quit = quit
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "Everest"
        refreshIcon()
        // The icon dims while the keyboard is away and shows a dot for a
        // missing permission.
        model.$connected.combineLatest(model.$accessibilityOK)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshIcon() }
            .store(in: &bag)
    }

    private func refreshIcon() {
        // The Mountain mark; a dot warns that a permission is missing.
        let img = MountainMark.menuBarImage(warning: !model.accessibilityOK)
        img.accessibilityDescription = "Everest"
        item.button?.image = img
        item.button?.appearsDisabled = !model.connected
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = model.connected ? model.attached : tr("menu.disconnected")
        let header = NSMenuItem(title: "Everest — \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if model.firmwareBlock != nil {
            let warn = NSMenuItem(title: tr("menu.firmwareBlocked"), action: nil, keyEquivalent: "")
            warn.image = NSImage(systemSymbolName: "exclamationmark.shield.fill", accessibilityDescription: nil)
            warn.isEnabled = false
            menu.addItem(warn)
        }

        if !model.accessibilityOK {
            menu.addItem(BlockItem(tr("menu.allowAccessibility"), symbol: "exclamationmark.triangle.fill") { [model] in
                model.openAccessibilitySettings()
            })
        }
        menu.addItem(.separator())

        // Profiles
        let profiles = NSMenu()
        for p in model.profiles {
            profiles.addItem(BlockItem(p.title, symbol: p.symbol, checked: p.id == model.config.selectedProfile) { [model] in
                model.switchProfile(to: p.id)
            })
        }
        profiles.addItem(.separator())
        if model.canAddProfile {
            profiles.addItem(BlockItem(tr("menu.newProfile"), symbol: "plus") { [model] in model.addProfile() })
        }
        profiles.addItem(BlockItem(tr("menu.manageProfiles"), symbol: "slider.horizontal.3") { [openWindow] in openWindow(.profiles) })
        let profileItem = NSMenuItem(title: tr("menu.profile", model.activeProfile?.title ?? "—"), action: nil, keyEquivalent: "")
        profileItem.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)
        profileItem.submenu = profiles
        menu.addItem(profileItem)

        // Lighting
        let lighting = NSMenu()
        let fwHeader = NSMenuItem(title: tr("menu.keyboardEffects"), action: nil, keyEquivalent: "")
        fwHeader.isEnabled = false
        lighting.addItem(fwHeader)
        for e in FirmwareLighting.Effect.allCases {
            let on = model.source == .firmware && model.firmwareLighting.effect == e
            lighting.addItem(BlockItem(e.title, symbol: e.icon, checked: on) { [model] in model.selectFirmware(e) })
        }
        lighting.addItem(.separator())
        let macHeader = NSMenuItem(title: tr("menu.macEffects"), action: nil, keyEquivalent: "")
        macHeader.isEnabled = false
        lighting.addItem(macHeader)
        for k in LedEffect.Kind.allCases where k != .solid {
            let on = model.source == .mac && model.effect.kind == k
            lighting.addItem(BlockItem(k.title, symbol: k.icon, checked: on) { [model] in model.selectEffect(k) })
        }
        if model.source == .mac {
            lighting.addItem(.separator())
            lighting.addItem(BlockItem(model.playing ? tr("menu.pauseEffect") : tr("menu.resumeEffect"),
                                       symbol: model.playing ? "pause.fill" : "play.fill") { [model] in
                model.togglePlayback()
            })
        }
        let lightItem = NSMenuItem(title: tr("lighting.title"), action: nil, keyEquivalent: "")
        lightItem.image = NSImage(systemSymbolName: "light.max", accessibilityDescription: nil)
        lightItem.submenu = lighting
        menu.addItem(lightItem)

        // Listener
        menu.addItem(BlockItem(tr("daemon.keysActive"), symbol: "square.grid.2x2.fill", checked: model.daemonActive) { [model] in
            model.toggleDaemon()
        })

        menu.addItem(.separator())

        // Language
        let languages = NSMenu()
        languages.addItem(BlockItem(tr("settings.language.automatic"), checked: model.language == nil) { [model] in
            model.setLanguage(nil)
        })
        languages.addItem(.separator())
        for l in Language.allCases {
            languages.addItem(BlockItem(l.nativeName, checked: model.language == l) { [model] in model.setLanguage(l) })
        }
        let langItem = NSMenuItem(title: tr("settings.language.title"), action: nil, keyEquivalent: "")
        langItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        langItem.submenu = languages
        menu.addItem(langItem)

        menu.addItem(BlockItem(tr("menu.open"), symbol: "macwindow", key: "o") { [openWindow] in openWindow(nil) })
        menu.addItem(BlockItem(tr("menu.launchAtLogin"), symbol: "power", checked: model.launchAtLogin) { [model] in
            model.setLaunchAtLogin(!model.launchAtLogin)
        })
        menu.addItem(.separator())
        menu.addItem(BlockItem(tr("app.quit"), key: "q") { [quit] in quit() })
    }
}
