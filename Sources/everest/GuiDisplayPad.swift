import AppKit
import SwiftUI

// MARK: - Model

extension EverestModel {
    /// Change one pad key of the selected profile and save.
    func updatePadKey(_ i: Int, _ change: (inout ButtonConfig) -> Void) {
        var b = config.padButtons
        change(&b[i])
        config.padButtons = b
        config.save()
    }

    /// The pad forgets its pictures when unplugged and they are sent again
    /// from the file, so a picked image is copied next to the app's own icons
    /// (moving or deleting the original must not blank the key).
    func setPadIcon(_ i: Int, url: URL) {
        var path = url.path
        if !path.hasPrefix(IconFactory.directory.path) {
            let copy = IconFactory.directory.appendingPathComponent("pad-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
            try? FileManager.default.createDirectory(at: IconFactory.directory, withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { path = copy.path }
        }
        updatePadKey(i) { $0.iconPath = path }
        drawPadKeys([i])
    }

    func applyPadPreset(_ preset: ButtonPreset, to i: Int, withAction: Bool) {
        guard let url = preset.appURL.flatMap({ IconFactory.render(app: $0) }) ?? IconFactory.render(preset) else {
            report(tr("status.iconDrawFailed"), error: true)
            return
        }
        if withAction, let action = preset.action {
            updatePadKey(i) { $0.action = action; $0.name = preset.name }
        }
        setPadIcon(i, url: url)
    }

    func assignPadApp(_ app: URL, to i: Int) {
        guard let icon = IconFactory.render(app: app) else {
            report(tr("status.appIconUnreadable"), error: true)
            return
        }
        updatePadKey(i) { b in
            b.action = ButtonAction(type: "app", value: app.path)
            b.name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        }
        setPadIcon(i, url: icon)
    }

    func setPadBrightness(_ percent: Int, commit: Bool = true) {
        config.padBrightness = PadProto.brightnessLevel(percent)
        guard commit else { return }
        config.save()
        guard !daemonRunning, padConnected else { return }   // the daemon applies it
        let level = config.padBrightness
        let buttons = config.padButtons
        padSession { pad in
            try pad.setBrightness(PadProto.backlight(for: level))
            try pad.setKeyImages((0..<PadProto.keyCount).map { ($0, PadDaemon.bgr(for: buttons[$0], brightness: level)) })
        }
    }

    /// The daemon redraws keys whose picture changed in the config within a
    /// second. Without it the app sends them itself.
    func drawPadKeys(_ keys: [Int]) {
        let label = keys.count == 1 ? "P\(keys[0] + 1)" : tr("section.displaypad.title")
        guard padConnected else {
            report(tr("pad.status.savedOffline", label))
            return
        }
        guard !daemonRunning else {
            report(tr("pad.status.sent", label))
            return
        }
        let buttons = config.padButtons
        let level = config.padBrightness
        padSession { pad in
            try pad.setKeyImages(keys.map { ($0, PadDaemon.bgr(for: buttons[$0], brightness: level)) })
        } done: { [weak self] in self?.report(tr("pad.status.sent", label)) }
    }

    private func padSession(_ body: @escaping (DisplayPad) throws -> Void, done: (() -> Void)? = nil) {
        padQueue.async { [weak self] in
            PadBusy.set()
            defer { PadBusy.clear() }
            do {
                let pad = try DisplayPad(startup: 3)
                defer { pad.close() }
                try body(pad)
                DispatchQueue.main.async { done?() }
            } catch {
                DispatchQueue.main.async { self?.report(tr("pad.status.failed", error.localizedDescription), error: true) }
            }
        }
    }
}

// MARK: - Page

struct DisplayPadPage: View {
    @ObservedObject var model: EverestModel
    @State private var selected = 0
    @State private var appearance: AppearanceTarget?
    private var tint: Color { Section.displaypad.tint }

    var body: some View {
        VStack(spacing: 18) {
            if !model.accessibilityOK {
                AccessibilityBanner(model: model)
            }
            if !model.daemonRunning {
                DaemonStoppedBanner(model: model, note: tr("pad.daemonStoppedNote"))
            }
            status
            grid
            ButtonEditorCard(model: model, target: .pad(selected), appearance: $appearance)
                .id(selected)
        }
        .sheet(item: $appearance) { t in KeyAppearanceSheet(model: model, target: t.target, tab: t.tab) }
    }

    /// Icon, colour, title and note for the status line: USB presence, then
    /// what the daemon found when it talked to the pad.
    private var state: (String, Color, String, String) {
        guard model.padConnected else {
            return ("cable.connector.slash", Theme.amber, tr("pad.notConnected"), tr("pad.notConnectedNote"))
        }
        switch model.padState?.status {
        case .unsupported:
            return ("exclamationmark.triangle.fill", Theme.danger,
                    tr("pad.unsupported", model.padState?.firmware ?? "?"), tr("pad.unsupportedNote"))
        case .noAnswer:
            return ("hourglass", Theme.amber, tr("pad.noAnswer"), tr("pad.noAnswerNote"))
        default:
            return ("checkmark.circle.fill", Theme.success, tr("pad.connected"), tr("pad.connectedNote"))
        }
    }

    private var status: some View {
        let (icon, color, title, note) = state
        return HStack(spacing: 14) {
            IconBadge(icon: icon, tint: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(note)
                    .font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(tr("pad.brightness"), value: "\(model.config.padBrightness) %")
                GlowSlider(value: Binding(get: { Double(model.config.padBrightness) },
                                          set: { model.setPadBrightness(Int($0.rounded()), commit: false) }),
                           range: 0...100, step: 5, tint: tint,
                           onCommit: { model.setPadBrightness(model.config.padBrightness) })
            }
            .frame(width: 300)
        }
        .padding(14)
        .background(SurfaceBackground())
    }

    private var grid: some View {
        Card(tr("pad.keys"), subtitle: tr("pad.keysNote", model.activeProfile?.title ?? ""),
             icon: "rectangle.split.3x1.fill", tint: tint) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: PadProto.columns), spacing: 12) {
                ForEach(0..<PadProto.keyCount, id: \.self) { i in
                    let b = model.config.padButtons[i]
                    Button { selected = i } label: {
                        VStack(spacing: 6) {
                            KeyScreen(image: model.image(for: .pad(i)), label: "P\(i + 1)", size: 84, factory: false)
                                .overlay(RoundedRectangle(cornerRadius: 84 * 0.16, style: .continuous)
                                    .strokeBorder(selected == i ? tint : .clear, lineWidth: 2.5))
                            Text(b.title.flatMap { $0.isEmpty ? nil : $0 } ?? "P\(i + 1)")
                                .font(.ui(11, selected == i ? .semibold : .regular))
                                .foregroundStyle(selected == i ? Theme.text : Theme.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(b.action.type == "none" ? tr("buttons.noAction")
                          : "\(ButtonsPage.types.first { $0.0 == b.action.type }?.2 ?? b.action.type): \(b.action.value)")
                }
            }
        }
    }
}
