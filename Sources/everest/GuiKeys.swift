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

extension EverestModel {
    func button(_ t: KeyTarget) -> ButtonConfig {
        t.isPad ? config.padButtons[t.index] : config.buttons[t.index]
    }

    func setButton(_ t: KeyTarget, name: String? = nil, type: String? = nil, value: String? = nil) {
        guard t.isPad else { return setButton(t.index, name: name, type: type, value: value) }
        updatePadKey(t.index) { b in
            if let name { b.name = name }
            if let type { b.action.type = type }
            if let value { b.action.value = value }
        }
    }

    func image(for t: KeyTarget) -> NSImage? {
        guard t.isPad else { return displayImages[t.index] }
        return config.padButtons[t.index].iconPath.flatMap { NSImage(contentsOfFile: $0) }
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
