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
/// frequent actions — profile and lighting — are one click away. Application
/// preferences and the key listener are managed inside the main window.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: EverestModel
    private let openWindow: (Section?) -> Void
    private let about: () -> Void
    private let quit: () -> Void
    private var bag = Set<AnyCancellable>()

    init(model: EverestModel, openWindow: @escaping (Section?) -> Void,
         about: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        self.about = about
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

        menu.addItem(BlockItem(tr("menu.about"), symbol: "info.circle") { [about] in about() })
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

        menu.addItem(.separator())

        menu.addItem(BlockItem(tr("menu.open"), symbol: "macwindow", key: "o") { [openWindow] in openWindow(nil) })
        menu.addItem(.separator())
        menu.addItem(BlockItem(tr("menu.quit"), key: "q") { [quit] in quit() })
    }
}
