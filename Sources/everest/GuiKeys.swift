import AppKit
import SwiftUI

/// A screen key the app can edit. The key editor (`ButtonEditorCard`) and
/// the appearance sheet work on a target rather than a D1–D4 index, so other
/// devices with screen keys can reuse them.
enum KeyTarget: Hashable {
    case dkey(Int)

    var index: Int {
        switch self {
        case .dkey(let i): return i
        }
    }

    var label: String { "D\(index + 1)" }
    var tint: Color { Section.buttons.tint }
}

extension EverestModel {
    func button(_ t: KeyTarget) -> ButtonConfig { config.buttons[t.index] }

    func setButton(_ t: KeyTarget, name: String? = nil, type: String? = nil, value: String? = nil) {
        setButton(t.index, name: name, type: type, value: value)
    }

    func image(for t: KeyTarget) -> NSImage? { displayImages[t.index] }

    /// 0…1 while a picture is being sent to this key.
    func uploading(_ t: KeyTarget) -> Double? {
        keyUpload?.button == t.index ? keyUpload?.progress : nil
    }

    func setIcon(_ t: KeyTarget, url: URL) { uploadIcon(button: t.index, url: url) }

    func applyPreset(_ preset: ButtonPreset, to t: KeyTarget, withAction: Bool) {
        applyPreset(preset, to: t.index, withAction: withAction)
    }

    func assignApp(_ app: URL, to t: KeyTarget) { assignApp(app, to: t.index) }

    func restoreFactory(_ t: KeyTarget) { restoreFactory(t.index) }

    func resetButtonIcon(_ t: KeyTarget) { resetButtonIcon(t.index) }
}
