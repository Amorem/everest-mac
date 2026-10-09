import AppKit
import SwiftUI

/// A screen key the app can edit: D1–D4 on the keyboard, or one of the
/// DisplayPad's twelve (P1–P12, left to right, top row first). The key
/// editor (`ButtonEditorCard`) and the appearance sheet work on a target.
enum KeyTarget: Hashable {
    case dkey(Int)
    case pad(Int)

    var index: Int {
        switch self {
        case .dkey(let i), .pad(let i): return i
        }
    }

    var isPad: Bool { if case .pad = self { return true } else { return false } }
    var label: String { (isPad ? "P" : "D") + "\(index + 1)" }
    var tint: Color { isPad ? Section.displaypad.tint : Section.buttons.tint }
}

/// Key pictures, decoded once per file version rather than on every redraw
/// (the keyboard preview redraws up to 30 times a second).
enum ImageFileCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String) -> NSImage? {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let key = "\(path)|\(date?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

extension EverestModel {
    func button(_ t: KeyTarget) -> ButtonConfig {
        t.isPad ? config.padButtons[t.index] : config.buttons[t.index]
    }

    func setButton(_ t: KeyTarget, name: String? = nil, type: ActionKind? = nil, value: String? = nil) {
        guard t.isPad else { return setButton(t.index, name: name, type: type, value: value) }
        updatePadKey(t.index, typing: type == nil) { b in
            if let name { b.name = name }
            if let type { b.action.type = type }
            if let value { b.action.value = value }
        }
    }

    func image(for t: KeyTarget) -> NSImage? {
        guard t.isPad else { return displayImages[t.index] }
        let b = config.padButtons[t.index]
        if let live = b.live, let cg = LiveTiles.image(live, sample: liveSample, side: 128) {
            return NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
        }
        return b.iconPath.flatMap(ImageFileCache.image)
    }

    /// 0…1 while a picture is being sent to this key (the pad takes a
    /// picture in a fraction of a second: no progress).
    func uploading(_ t: KeyTarget) -> Double? {
        !t.isPad && keyUpload?.button == t.index ? keyUpload?.progress : nil
    }

    func setIcon(_ t: KeyTarget, url: URL) {
        guard t.isPad else { return uploadIcon(button: t.index, url: url) }
        setPadIcon(t.index, url: url)
    }

    func applyPreset(_ preset: ButtonPreset, to t: KeyTarget, withAction: Bool) {
        guard t.isPad else { return applyPreset(preset, to: t.index, withAction: withAction) }
        applyPadPreset(preset, to: t.index, withAction: withAction)
    }

    func assignApp(_ app: URL, to t: KeyTarget) {
        guard t.isPad else { return assignApp(app, to: t.index) }
        assignPadApp(app, to: t.index)
    }

    /// D1–D4: factory picture and action. A pad key: blank.
    func restoreFactory(_ t: KeyTarget) {
        guard t.isPad else { return restoreFactory(t.index) }
        updatePadKey(t.index) { $0 = PadKeys.button(t.index) }
        drawPadKeys([t.index])
    }

    func resetButtonIcon(_ t: KeyTarget) {
        guard t.isPad else { return resetButtonIcon(t.index) }
        updatePadKey(t.index) { $0.iconPath = nil }
        drawPadKeys([t.index])
    }
}
