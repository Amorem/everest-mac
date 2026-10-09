import AppKit
import SwiftUI

// MARK: - Model

extension EverestModel {
    /// Change one pad key of the selected profile and save (`typing`: once
    /// the typing pauses).
    func updatePadKey(_ i: Int, typing: Bool = false, _ change: (inout ButtonConfig) -> Void) {
        var b = config.padButtons
        change(&b[i])
        config.padButtons = b
        if typing { persistSoon() } else { persist() }
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
        persist()
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
            DisplayPadHero(model: model, keySize: 86, selected: selected) { selected = $0 }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }
}

// MARK: - Device drawing

/// The DisplayPad as it sits on the desk: a dark body, one screen behind
/// twelve keys, each showing its picture. Clickable on the DisplayPad page.
struct DisplayPadHero: View {
    @ObservedObject var model: EverestModel
    var keySize: CGFloat = 72
    var selected: Int? = nil
    var onSelect: ((Int) -> Void)? = nil
    private var gap: CGFloat { keySize * 0.16 }

    var body: some View {
        let tint = Section.displaypad.tint
        ZStack {
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<PadProto.columns, id: \.self) { col in key(row * PadProto.columns + col) }
                    }
                }
            }
            .padding(keySize * 0.22)
            .background(
                // The one screen the keys sit over.
                RoundedRectangle(cornerRadius: keySize * 0.16, style: .continuous)
                    .fill(Color(hex: 0x050608))
                    .overlay(RoundedRectangle(cornerRadius: keySize * 0.16, style: .continuous)
                        .strokeBorder(.white.opacity(0.06)))
            )
            .padding(keySize * 0.24)
            .background(
                RoundedRectangle(cornerRadius: keySize * 0.3, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x2B2E35), Color(hex: 0x16171B)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: keySize * 0.3, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .black.opacity(0.55), radius: keySize * 0.25, y: keySize * 0.1)
                    .shadow(color: tint.opacity(0.25), radius: keySize * 0.6)
            )
        }
    }

    private func key(_ i: Int) -> some View {
        let r = keySize * 0.14
        let image = model.image(for: .pad(i))
        let isSelected = selected == i
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous).fill(Color.black)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .opacity(0.25 + 0.75 * Double(model.config.padBrightness) / 100)
            } else if onSelect != nil {
                Text("P\(i + 1)").font(.system(size: keySize * 0.2, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.18))
            }
            // Keycap: a clear plastic edge with a highlight on top.
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            if isSelected {
                RoundedRectangle(cornerRadius: r + 3, style: .continuous)
                    .strokeBorder(Section.displaypad.tint, lineWidth: 2.5)
                    .padding(-4)
            }
        }
        .frame(width: keySize, height: keySize)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous).inset(by: -5))
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(i) }
        .help(model.config.padButtons[i].title.flatMap { $0.isEmpty ? nil : $0 } ?? "P\(i + 1)")
    }
}

/// Overview card, shown while the DisplayPad is plugged in.
struct DisplayPadCard: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        let tint = Section.displaypad.tint
        let assigned = model.config.padButtons.filter { $0.action.type != "none" }.count
        HStack(alignment: .center, spacing: 28) {
            DisplayPadHero(model: model, keySize: 62)
                .onTapGesture { model.section = .displaypad }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    IconBadge(icon: Section.displaypad.icon, tint: tint, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("section.displaypad.title")).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                        Text(subtitle).font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 10) {
                    Pill(text: tr("pad.overview.keys", "\(assigned)"), icon: "rectangle.split.3x1", tint: Theme.textSecondary)
                    Pill(text: "\(model.config.padBrightness) %", icon: "sun.max", tint: Theme.textSecondary)
                    if let fw = model.padState?.firmware {
                        Pill(text: tr("pad.overview.firmware", fw), icon: "cpu", tint: Theme.textSecondary)
                    }
                }
                Button { model.section = .displaypad } label: {
                    Label(tr("common.configure"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SurfaceBackground(radius: 18))
    }

    private var subtitle: String {
        switch model.padState?.status {
        case .unsupported: return tr("pad.unsupported", model.padState?.firmware ?? "?")
        case .noAnswer: return tr("pad.noAnswer")
        default: return model.daemonActive ? tr("overview.actionsActive") : tr("daemon.stopped")
        }
    }
}
