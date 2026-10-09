import AppKit
import SwiftUI

/// A ready-made setup for a display key: an icon drawn by the app and,
/// usually, the action that goes with it.
///
/// The icons copy the factory ones (see `FactoryIcons`): one flat colour, no
/// gradient or highlight, and a pure white glyph filling ~60 % of the key.
/// The LCD is 72 × 72 with a ~64 px visible area, so fine detail and soft
/// effects only turn into mush.
struct ButtonPreset: Identifiable {
    enum Category: String, CaseIterable {
        case media, system, apps, decor

        var title: String {
            switch self {
            case .media: return tr("preset.category.media")
            case .system: return tr("section.system.title")
            case .apps: return tr("preset.category.apps")
            case .decor: return tr("preset.category.decor")
            }
        }
    }

    let id: String
    let name: String
    let symbol: String
    let color: UInt32
    let category: Category
    let action: ButtonAction?

    var tint: Color { Color(hex: color) }

    /// For app presets: the installed app, whose real icon is used.
    var appURL: URL? {
        guard let a = action, a.type == .app, FileManager.default.fileExists(atPath: a.value) else { return nil }
        return URL(fileURLWithPath: a.value)
    }

    private static let blue = FactoryIcons.blue

    static var all: [ButtonPreset] { [
        // Media keys (consumer-control events, no permission needed)
        .init(id: "playpause", name: tr("preset.playpause"), symbol: "playpause.fill", color: 0xFF1F5A,
              category: .media, action: .init(type: .keypress, value: "playpause")),
        .init(id: "next", name: tr("preset.next"), symbol: "forward.fill", color: 0xFF1F5A,
              category: .media, action: .init(type: .keypress, value: "next")),
        .init(id: "prev", name: tr("preset.previous"), symbol: "backward.fill", color: 0xFF1F5A,
              category: .media, action: .init(type: .keypress, value: "prev")),
        .init(id: "mute", name: tr("preset.mute"), symbol: "speaker.slash.fill", color: 0xFF7A00,
              category: .media, action: .init(type: .keypress, value: "mute")),
        .init(id: "volup", name: tr("preset.volumeUp"), symbol: "speaker.wave.3.fill", color: 0xFF7A00,
              category: .media, action: .init(type: .keypress, value: "volup")),
        .init(id: "voldown", name: tr("preset.volumeDown"), symbol: "speaker.wave.1.fill", color: 0xFF7A00,
              category: .media, action: .init(type: .keypress, value: "voldown")),

        // System
        .init(id: "capture-zone", name: tr("preset.captureZone"), symbol: "camera.viewfinder", color: blue,
              category: .system, action: .init(type: .keypress, value: "cmd+shift+4")),
        .init(id: "capture-screen", name: tr("preset.captureScreen"), symbol: "camera.fill", color: blue,
              category: .system, action: .init(type: .keypress, value: "cmd+shift+3")),
        .init(id: "spotlight", name: "Spotlight", symbol: "magnifyingglass", color: blue,
              category: .system, action: .init(type: .keypress, value: "cmd+space")),
        .init(id: "mission", name: "Mission Control", symbol: "rectangle.3.group.fill", color: blue,
              category: .system, action: .init(type: .keypress, value: "ctrl+up")),
        .init(id: "lock", name: tr("preset.lock"), symbol: "lock.fill", color: 0x5B21FF,
              category: .system, action: .init(type: .keypress, value: "ctrl+cmd+q")),
        .init(id: "sleep", name: tr("preset.sleepDisplay"), symbol: "display", color: 0x5B21FF,
              category: .system, action: .init(type: .shell, value: "pmset displaysleepnow")),

        // Apps (open, or bring to the front if already open) — real app icons
        .init(id: "app-finder", name: "Finder", symbol: "folder.fill", color: blue,
              category: .apps, action: .init(type: .app, value: "/System/Library/CoreServices/Finder.app")),
        .init(id: "app-terminal", name: "Terminal", symbol: "terminal.fill", color: 0x111111,
              category: .apps, action: .init(type: .app, value: "/System/Applications/Utilities/Terminal.app")),
        .init(id: "app-safari", name: "Safari", symbol: "safari.fill", color: blue,
              category: .apps, action: .init(type: .app, value: "/Applications/Safari.app")),
        .init(id: "app-mail", name: "Mail", symbol: "envelope.fill", color: blue,
              category: .apps, action: .init(type: .app, value: "/System/Applications/Mail.app")),
        .init(id: "app-messages", name: "Messages", symbol: "message.fill", color: 0x00C44F,
              category: .apps, action: .init(type: .app, value: "/System/Applications/Messages.app")),
        .init(id: "app-music", name: tr("preset.music"), symbol: "music.note", color: 0xFF1F5A,
              category: .apps, action: .init(type: .app, value: "/System/Applications/Music.app")),
        .init(id: "app-calendar", name: tr("preset.calendar"), symbol: "calendar", color: 0xFF3B30,
              category: .apps, action: .init(type: .app, value: "/System/Applications/Calendar.app")),
        .init(id: "app-notes", name: "Notes", symbol: "note.text", color: 0xFFB800,
              category: .apps, action: .init(type: .app, value: "/System/Applications/Notes.app")),

        // Decorative
        .init(id: "star", name: tr("preset.star"), symbol: "star.fill", color: 0xFFB800, category: .decor, action: nil),
        .init(id: "heart", name: tr("preset.heart"), symbol: "heart.fill", color: 0xFF1F5A, category: .decor, action: nil),
        .init(id: "bolt", name: tr("preset.bolt"), symbol: "bolt.fill", color: 0xFF7A00, category: .decor, action: nil),
        .init(id: "flame", name: tr("preset.flame"), symbol: "flame.fill", color: 0xFF3B30, category: .decor, action: nil),
        .init(id: "game", name: tr("preset.game"), symbol: "gamecontroller.fill", color: 0x5B21FF, category: .decor, action: nil),
        .init(id: "code", name: "Code", symbol: "chevron.left.forwardslash.chevron.right", color: blue,
              category: .decor, action: nil),
        .init(id: "home", name: tr("preset.home"), symbol: "house.fill", color: 0x00C44F, category: .decor, action: nil),
        .init(id: "coffee", name: tr("preset.coffee"), symbol: "cup.and.saucer.fill", color: 0x9A4B00, category: .decor, action: nil),
    ] }
}

/// The artwork sent to a display key for a preset, drawn like the factory
/// icons: flat colour, pure white glyph at ~62 % of the key. Sizes are
/// relative, so the same view is the preview (any size) and the 256 px source.
struct PresetIconView: View {
    let preset: ButtonPreset
    /// Glyph box as a fraction of the key (factory glyphs span 48–73 %).
    static let glyph: CGFloat = 0.62

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            ZStack {
                Color(hex: preset.color)
                Image(systemName: preset.symbol)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.heavy)
                    .foregroundStyle(.white)
                    .frame(width: side * Self.glyph, height: side * Self.glyph)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// An app's own icon on the black LCD, nearly edge to edge (macOS icons
/// already carry a small margin).
struct AppIconTile: View {
    let icon: NSImage
    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            ZStack {
                Color.black
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: side * 0.9, height: side * 0.9)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// App icons without the alias arrow macOS stamps on symlinks
/// (`/Applications/Safari.app` is one).
enum AppIcons {
    static func icon(forFile path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }
}

enum IconFactory {
    static var directory: URL { Config.directory.appendingPathComponent("icons", isDirectory: true) }

    /// Render a SwiftUI view to a 256 px PNG in the icons folder (the upload
    /// downsamples it to the key's 72 × 72).
    @MainActor
    static func write<V: View>(_ view: V, name: String) -> URL? {
        let renderer = ImageRenderer(content: view.frame(width: 256, height: 256))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    @MainActor
    static func render(_ preset: ButtonPreset) -> URL? {
        write(PresetIconView(preset: preset), name: "preset-" + preset.id)
    }

    @MainActor
    static func render(app url: URL) -> URL? {
        let icon = AppIcons.icon(forFile: url.path)
        icon.size = NSSize(width: 512, height: 512)
        let id = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        return write(AppIconTile(icon: icon), name: "app-" + id.replacingOccurrences(of: "/", with: "_"))
    }
}

/// Installed applications, for the app picker.
struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: String { url.path }

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        func add(_ url: URL) {
            guard url.pathExtension == "app", !seen.contains(url.path) else { return }
            seen.insert(url.path)
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            apps.append(InstalledApp(url: url, name: name))
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root),
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let sub = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]) {
                    // App suites in folders (e.g. /Applications/Adobe …/).
                    sub.forEach(add)
                }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
