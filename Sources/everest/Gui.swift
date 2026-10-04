import AppKit
import Combine
import SwiftUI

/// SwiftUI interface — `everest gui`, or Everest.app.
enum Gui {
    /// Called from main.swift, which runs on the main thread.
    static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = EverestAppDelegate()
            app.delegate = delegate
            app.activate(ignoringOtherApps: true)
            app.run()
        }
    }
}

@MainActor
final class EverestAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    let model = EverestModel()
    var statusBar: StatusBarController?
    private var launchedAtLogin = false

    /// True when macOS started the app as a login item: it should come up
    /// quietly in the menu bar, without opening its window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEKeyword(keyAELaunchedAsLogInItem)
    }

    /// Bring the window up (and the Dock icon with it).
    func showWindow(_ section: Section? = nil) {
        if let section { model.section = section }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window keeps Everest running in the menu bar.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if model.config.keepRunning {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopEverything()
    }

    private var bag = Set<AnyCancellable>()

    /// The menu bar of the app itself (not the status-item menu, which is
    /// rebuilt every time it opens).
    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("app.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("app.closeWindow"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: tr("app.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: tr("app.edit"))
        editMenu.addItem(withTitle: tr("app.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("app.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("app.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("app.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // The app menu is built once, so rebuild it when the language changes.
        model.$config.map(\.language).removeDuplicates()
            .sink { [weak self] _ in self?.buildMainMenu() }
            .store(in: &bag)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Everest"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.043, green: 0.047, blue: 0.067, alpha: 1)
        window.minSize = NSSize(width: 1080, height: 720)
        window.center()
        window.setFrameAutosaveName("EverestMain")
        window.contentView = NSHostingView(rootView: RootView(model: model))
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        model.start()
        statusBar = StatusBarController(model: model,
                                        openWindow: { [weak self] section in self?.showWindow(section) },
                                        quit: { [weak self] in
                                            self?.model.stopEverything()
                                            NSApp.terminate(nil)
                                        })
        if launchedAtLogin && model.config.keepRunning {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showWindow()
        }

        // Diagnostic hook: start the LED player automatically at launch.
        if ProcessInfo.processInfo.environment["EVEREST_GUI_LEDTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.startPlayer() }
        }
        // Diagnostic hook: render every page to PNG files in this folder, then quit.
        if let dir = ProcessInfo.processInfo.environment["EVEREST_SNAPSHOT"] {
            snapshotPages(into: dir, sections: Section.allCases)
        }
    }

    private func snapshotSheets(into dir: String, tabs: [KeyAppearanceSheet.Tab]) {
        guard let tab = tabs.first else {
            NSApp.terminate(nil)
            return
        }
        let host = NSHostingView(rootView: KeyAppearanceSheet(model: model, button: 0, tab: tab))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("sheet-\(tab).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            w.close()
            self.snapshotSheets(into: dir, tabs: Array(tabs.dropFirst()))
        }
    }

    private func snapshotPages(into dir: String, sections: [Section]) {
        guard let first = sections.first else {
            snapshotSheets(into: dir, tabs: [.presets, .apps])
            return
        }
        if let source = ProcessInfo.processInfo.environment["EVEREST_SNAPSHOT_SOURCE"] {
            model.source = source == "mac" ? .mac : .firmware
        }
        model.section = first
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let view = self.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(first.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            self.snapshotPages(into: dir, sections: Array(sections.dropFirst()))
        }
    }

}

// MARK: - Root

struct RootView: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            ZStack(alignment: .top) {
                AmbientBackground(color: dominantColor(model.previewMain, model.previewSide))
                VStack(spacing: 0) {
                    PageHeader(model: model)
                    ScrollView {
                        content
                            .padding(.horizontal, 28)
                            .padding(.top, 4)
                            .padding(.bottom, 28)
                            .frame(maxWidth: 1200)
                            .frame(maxWidth: .infinity)
                    }
                    StatusBar(model: model)
                }
            }
        }
        .overlay { if let block = model.firmwareBlock { FirmwareBlockView(model: model, block: block) } }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // A language change rebuilds every view: strings are read when drawn.
        .id(L10n.current)
        .environment(\.layoutDirection, L10n.current.isRightToLeft ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder private var content: some View {
        switch model.section {
        case .overview: OverviewPage(model: model)
        case .profiles: ProfilesPage(model: model)
        case .lighting: LightingPage(model: model)
        case .displays: DisplaysPage(model: model)
        case .buttons: ButtonsPage(model: model)
        case .keyboard: KeyboardLayoutPage(model: model)
        case .system: SystemPage(model: model)
        }
    }
}

/// Dark canvas with a soft glow tinted by whatever the keyboard shows.
struct AmbientBackground: View {
    var color: Color
    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [color.opacity(0.16), .clear], center: UnitPoint(x: 0.5, y: -0.05),
                           startRadius: 20, endRadius: 620)
                .animation(.easeInOut(duration: 1.2), value: color)
            RadialGradient(colors: [Theme.violet.opacity(0.06), .clear], center: UnitPoint(x: 1.0, y: 1.0),
                           startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: 10) {
                BrandTile(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Everest").font(.ui(15, .bold)).foregroundStyle(Theme.text)
                    Text(tr("app.tagline")).font(.ui(11, .medium)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 18)
            .padding(.top, 46)
            .padding(.bottom, 16)

            ProfileSwitcher(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(Section.allCases) { s in
                    SidebarItem(section: s, selected: model.section == s) {
                        withAnimation(.easeOut(duration: 0.15)) { model.section = s }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            DeviceCard(model: model)
                .padding(12)
        }
        .frame(width: 228)
        .background(
            ZStack {
                VisualEffect(material: .sidebar)
                Color.black.opacity(0.35)
            }
        )
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.stroke).frame(width: 1) }
    }
}

struct SidebarItem: View {
    let section: Section
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(icon: section.icon, tint: section.tint, size: 24)
                Text(section.title)
                    .font(.ui(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.09) : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DeviceCard: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(on: model.connected)
                Text(model.connected ? tr("device.connected") : tr("device.disconnected"))
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    model.refreshDevice()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.ui(10.5, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help(tr("device.refresh.help"))
            }
            Text(model.attached)
                .font(.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                miniStat(tr("device.firmware"), model.firmware)
                miniStat(tr("device.dial"), DisplaysPage.modeTitle(model.dialMode))
            }
            HStack(spacing: 6) {
                StatusDot(on: model.daemonActive, color: Theme.indigo)
                Text(model.daemonActive ? tr("daemon.keysActive") : tr("daemon.stopped"))
                    .font(.ui(11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .background(SurfaceBackground(radius: 12, fill: Color.white.opacity(0.04)))
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.ui(9.5, .medium)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.ui(11.5, .semibold).monospacedDigit()).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}

// MARK: - Header & status

struct PageHeader: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.section.title)
                    .font(.ui(24, .bold))
                    .foregroundStyle(Theme.text)
                Text(model.section.subtitle)
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if model.section == .overview || model.section == .lighting {
                LiveBadge(model: model)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .padding(.bottom, 18)
    }
}

/// What the keyboard is doing right now.
struct LiveBadge: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.playing ? Theme.success : (model.source == .firmware ? Theme.sky : Theme.textTertiary))
                    .frame(width: 7, height: 7)
                Text(label).font(.ui(12, .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
            if model.source == .mac {
                Button {
                    model.togglePlayback()
                } label: {
                    Label(model.playing ? tr("live.pause") : tr("live.start"), systemImage: model.playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.primary)
            }
        }
    }

    private var label: String {
        switch model.source {
        case .firmware: return tr("live.keyboard", model.firmwareLighting.effect.title)
        case .mac: return model.playing ? tr("live.mac", model.effect.kind.title) : tr("live.macPaused")
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.ui(11, .semibold))
                .foregroundStyle(model.statusIsError ? Theme.danger : Theme.success.opacity(0.8))
            Text(model.status)
                .font(.ui(11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            if let p = model.progress {
                Text("\(Int(p * 100)) %")
                    .font(.ui(11, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.accentGradient).frame(width: 180 * p)
                }
                .frame(width: 180, height: 5)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 34)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

/// The keyboard hero with the ambient glow, used on several pages.
struct KeyboardHero: View {
    @ObservedObject var model: EverestModel
    var height: CGFloat = 330
    var paintable = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [dominantColor(model.previewMain, model.previewSide).opacity(0.30), .clear],
                           center: .center, startRadius: 10, endRadius: 520)
                .blur(radius: 30)
            KeyboardCanvas(main: model.previewMain, side: model.previewSide,
                           displayImages: model.displayImages,
                           paintable: paintable,
                           onPaint: { model.paintKey($0) }) {
                DialFace(mode: Proto.MainMode(rawValue: model.config.mainDisplayMode) ?? .clock,
                         clockStyle: model.config.clockStyle, image: model.dialImage)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: height)
    }
}

// MARK: - Contact sheet (development aid)

extension Gui {
    /// `everest effect-sheet out.png` — every Mac and firmware effect at a few
    /// moments, rendered with the same canvas as the app.
    @MainActor
    static func effectSheet(to path: String) {
        var effect = (Config.load().lighting ?? LightingConfig()).mac
        effect.perKey = [:]
        let times: [Double] = [0.5, 1.7, 3.1, 4.6]
        let rows: [(String, (Double) -> LedRenderer.Frame)] =
            LedEffect.Kind.allCases.map { k in
                var e = effect
                e.kind = k
                return (k.title, { LedRenderer.render(e, time: $0) })
            } + FirmwareLighting.Effect.allCases.map { fx in
                var fw = FirmwareLighting()
                fw.effect = fx
                return ("FW " + fx.title, { LedRenderer.render(fw, time: $0) })
            }
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Text(row.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 110, alignment: .leading)
                    ForEach(times, id: \.self) { t in
                        let f = row.1(t)
                        KeyboardCanvas(main: f.main, side: f.side, style: .compact)
                            .frame(width: 230, height: 66)
                            .background(Color.black)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x111216))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1.5
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            fail("could not render the sheet")
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

extension Gui {
    /// `everest icon-sheet out.png` — the factory icons next to every preset,
    /// downsampled to the LCD's real 72 × 72 and enlarged 2× without
    /// smoothing, so what the key will show can be judged.
    @MainActor
    static func iconSheet(to path: String) {
        func lcd(_ image: NSImage) -> NSImage? {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = CGContext(data: nil, width: 72, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 72, height: 72))
            return ctx.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 72, height: 72)) }
        }
        var tiles: [(String, NSImage)] = []
        for i in 0..<4 { if let f = FactoryIcons.image(i), let l = lcd(f) { tiles.append(("D\(i + 1) usine", l)) } }
        for p in ButtonPreset.all {
            let url = p.appURL.flatMap { IconFactory.render(app: $0) } ?? IconFactory.render(p)
            if let url, let img = NSImage(contentsOf: url), let l = lcd(img) { tiles.append((p.name, l)) }
        }
        let sheet = LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 10), count: 8), spacing: 14) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                VStack(spacing: 4) {
                    Image(nsImage: t.1).resizable().interpolation(.none).frame(width: 144, height: 144)
                    Text(t.0).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 8 * 160 + 32)
        .background(Color(hex: 0x111216))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            fail("could not render the sheet")
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

extension Gui {
    /// `everest layout-sheet out.png` — the keyboard drawn for several layouts.
    @MainActor
    static func layoutSheet(to path: String) {
        let layouts: [KeyboardLayout] = [.us, .uk, .french, .german, .spanish, .nordic, .hebrew]
        // One render per layout: the canvas reads the active layout when it
        // draws, so each has to be rendered before the next one is selected.
        var images: [(KeyboardLayout, NSImage)] = []
        for l in layouts {
            LedLayout.use(l)
            let board = KeyboardCanvas(main: (0..<LedLayout.mainLedCount).map { _ in RGB(r: 0, g: 160, b: 255) },
                                       side: [RGB](repeating: RGB(r: 0, g: 120, b: 255), count: LedLayout.sideLedCount))
                .frame(width: 1180, height: 250)
                .background(Color(hex: 0x111216))
            let r = ImageRenderer(content: board)
            r.scale = 1
            if let img = r.nsImage { images.append((l, img)) }
        }
        let sheet = VStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.0.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Image(nsImage: item.1)
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x111216))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            fail("could not render the sheet")
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}

extension Gui {
    /// `everest menubar-sheet out.png` — the menu-bar icon enlarged, tinted
    /// the way macOS does for a light and a dark menu bar.
    @MainActor
    static func menuBarSheet(to path: String) {
        func tinted(_ warning: Bool, _ color: NSColor) -> NSImage {
            let src = MountainMark.menuBarImage(warning: warning)
            let scale: CGFloat = 8
            let size = NSSize(width: src.size.width * scale, height: src.size.height * scale)
            return NSImage(size: size, flipped: false) { rect in
                src.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
        }
        let sheet = HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                let warning = i % 2 == 1
                let light = i < 2
                Image(nsImage: tinted(warning, light ? .black : .white))
                    .padding(20)
                    .background(Color(hex: light ? 0xE9E9EB : 0x2A2A2D))
            }
        }
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            fail("could not render the sheet")
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}
