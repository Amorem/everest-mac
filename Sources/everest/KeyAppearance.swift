import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet to choose what a display key shows: a preset (icon + action), an
/// installed app (its icon; the key opens it or brings it forward), or any
/// image.
struct KeyAppearanceSheet: View {
    enum Tab: Hashable { case presets, apps, image, live }

    @ObservedObject var model: EverestModel
    let target: KeyTarget
    @State var tab: Tab = .presets
    @Environment(\.dismiss) private var dismiss
    @State private var withAction = true
    @State private var search = ""
    @State private var apps: [InstalledApp] = []
    @State private var pickingImage = false
    @State private var pickingApp = false
    @State private var started = false
    private var myUpload: EverestModel.KeyUpload? {
        !target.isPad && model.keyUpload?.button == target.index ? model.keyUpload : nil
    }
    /// The DisplayPad takes a picture in a fraction of a second: no upload
    /// panel, the sheet closes at once.
    private var busy: Bool { !target.isPad && model.keyUpload != nil }
    private var tint: Color { target.tint }

    private func begin(_ run: () -> Void) {
        run()
        if target.isPad { dismiss() } else { started = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                KeyScreen(image: model.image(for: target), label: target.label, size: 52,
                          uploading: myUpload?.progress, factory: !target.isPad)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("keyappearance.title", target.label)).font(.ui(17, .bold)).foregroundStyle(Theme.text)
                    Text(tr("keyappearance.subtitle"))
                        .font(.ui(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                IconButton(icon: "xmark", help: tr("common.close")) { dismiss() }
            }
            if let u = myUpload {
                UploadPanel(upload: u) { dismiss() }
            } else {
            if busy, let other = model.keyUpload {
                Caption(tr("keyappearance.busyOther", "D\(other.button + 1)"),
                        icon: "hourglass")
            }
            if started && model.statusIsError {
                Caption(model.status, icon: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
            }
            Segmented(items: [.init(value: Tab.presets, title: tr("keyappearance.presets"), icon: "square.grid.3x3.fill"),
                              .init(value: Tab.apps, title: tr("keyappearance.apps"), icon: "app.dashed"),
                              .init(value: Tab.image, title: tr("mode.image"), icon: "photo")]
                              // Live values: DisplayPad keys only (D1–D4 pictures live in flash).
                              + (target.isPad ? [.init(value: Tab.live, title: tr("keyappearance.live"), icon: "gauge.with.dots.needle.50percent")] : []),
                      selection: $tab, tint: tint, fill: true)

            Group {
                switch tab {
                case .presets: presets
                case .apps: appsTab
                case .image: imageTab
                case .live: liveTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .disabled(busy)
            .opacity(busy ? 0.45 : 1)
            }
        }
        .padding(22)
        .onChange(of: model.keyUpload == nil) { idle in
            // Close once this key has been updated; stay open on failure.
            if idle && started && !model.statusIsError { dismiss() }
        }
        .frame(width: 680, height: 600)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $pickingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                begin { model.setIcon(target, url: url) }
            }
        }
        .fileImporter(isPresented: $pickingApp, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result {
                begin { model.assignApp(url, to: target) }
            }
        }
    }

    // MARK: Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $withAction) {
                Text(tr("keyappearance.alsoAction")).font(.ui(12.5)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ButtonPreset.Category.allCases, id: \.self) { cat in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cat.title.uppercased()).font(.ui(10.5, .bold)).tracking(0.8)
                                .foregroundStyle(Theme.textTertiary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                                ForEach(ButtonPreset.all.filter { $0.category == cat }) { p in
                                    PickerTile(title: p.name, subtitle: actionLabel(p.action)) {
                                        if let app = p.appURL {
                                            Image(nsImage: AppIcons.icon(forFile: app.path))
                                                .resizable().interpolation(.high)
                                                .frame(width: 56, height: 56)
                                                .frame(width: 64, height: 64)
                                                .background(Color.black)
                                        } else {
                                            PresetIconView(preset: p)
                                                .frame(width: 64, height: 64)
                                        }
                                    } action: {
                                        begin { model.applyPreset(p, to: target, withAction: withAction) }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func actionLabel(_ a: ButtonAction?) -> String? {
        guard let a else { return nil }
        switch a.type {
        case .app: return tr("keyappearance.opensApp")
        case .keypress: return a.value
        case .shell: return tr("action.shell")
        default: return nil
        }
    }

    // MARK: Apps

    private var filtered: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StyledField(placeholder: tr("keyappearance.searchApp"), text: $search, icon: "magnifyingglass")
                Button { pickingApp = true } label: { Label(tr("common.other"), systemImage: "folder") }
                    .buttonStyle(.secondary)
            }
            Caption(tr("keyappearance.appHint"), icon: "info.circle")
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                    ForEach(filtered) { app in
                        PickerTile(title: app.name, subtitle: nil) {
                            Image(nsImage: AppIcons.icon(forFile: app.url.path))
                                .resizable().interpolation(.high)
                                .frame(width: 56, height: 56)
                                .frame(width: 64, height: 64)
                                .background(Color.black)
                        } action: {
                            begin { model.assignApp(app.url, to: target) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            guard apps.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let list = InstalledApp.scan()
                DispatchQueue.main.async { apps = list }
            }
        }
    }

    // MARK: Live

    private var liveTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $withAction) {
                Text(tr("keyappearance.liveAction")).font(.ui(12.5)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            Caption(tr("keyappearance.liveNote"), icon: "info.circle")
            if CodexBarUsage.isAvailable {
                Caption(tr("keyappearance.liveCodexBar"), icon: "sparkle")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                ForEach(LiveMetric.allCases.filter(\.isAvailable), id: \.self) { m in
                    PickerTile(title: m.title, subtitle: nil) {
                        Group {
                            if let cg = LiveTiles.image(m, sample: model.liveSample, side: 128) {
                                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 64, height: 64))).resizable()
                            }
                        }
                        .frame(width: 64, height: 64)
                    } action: {
                        begin { model.setLive(m, to: target.index, withAction: withAction) }
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: Image

    private var imageTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(Theme.strokeStrong)
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(tint)
                        Text(tr("keyappearance.imageFormats")).font(.ui(11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("keyappearance.ownImage")).font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                    Text(tr(target.isPad ? "pad.ownImageNote" : "keyappearance.ownImageNote"))
                        .font(.ui(12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button { pickingImage = true } label: { Label(tr("keyappearance.chooseFile"), systemImage: "photo") }
                            .buttonStyle(.primary(tint))
                        Button {
                            model.resetButtonIcon(target)
                            dismiss()
                        } label: {
                            Label(tr(target.isPad ? "pad.noImage" : "displays.factoryIcon"),
                                  systemImage: target.isPad ? "eraser" : "arrow.uturn.backward")
                        }
                            .buttonStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A selectable tile with artwork and a caption.
struct PickerTile<Art: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var art: Art
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                art
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                Text(title).font(.ui(11, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.ui(9.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.07) : .clear))
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Live view of a transfer to a display key.
struct UploadPanel: View {
    let upload: EverestModel.KeyUpload
    let onBackground: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = Int(ctx.date.timeIntervalSince(upload.started))
            VStack(spacing: 22) {
                Spacer(minLength: 10)
                ZStack {
                    ProgressRing(value: upload.progress, lineWidth: 7)
                        .frame(width: 190, height: 190)
                    KeyScreen(image: upload.preview, label: "D\(upload.button + 1)", size: 120)
                    if upload.finished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 34)).foregroundStyle(Theme.success)
                            .background(Circle().fill(Theme.surface).padding(2))
                            .offset(x: 70, y: 70)
                    }
                }
                VStack(spacing: 6) {
                    Text(upload.phase).font(.ui(16, .semibold)).foregroundStyle(Theme.text)
                    Text("\(Int(upload.progress * 100)) % · \(elapsed) s")
                        .font(.ui(12.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                PhaseSteps(progress: upload.progress, finished: upload.finished)
                Caption(tr("keyappearance.transferNote"),
                        icon: "info.circle")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Spacer(minLength: 10)
                Button(tr("keyappearance.background"), action: onBackground).buttonStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct PhaseSteps: View {
    let progress: Double
    let finished: Bool
    private let steps: [(String, Double)] = [(tr("keyappearance.step.prepare"), 0.52), (tr("keyappearance.step.send"), 0.98), (tr("status.displayLabel"), 1.0)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                let start = i == 0 ? 0 : steps[i - 1].1
                let done = finished || progress >= step.1
                let active = !done && progress >= start
                HStack(spacing: 5) {
                    Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.dotted" : "circle"))
                        .foregroundStyle(done ? Theme.success : (active ? Theme.indigo : Theme.textTertiary))
                    Text(step.0).font(.ui(11.5, active ? .semibold : .regular))
                        .foregroundStyle(active || done ? Theme.text : Theme.textTertiary)
                }
                if i < steps.count - 1 {
                    Rectangle().fill(done ? Theme.success.opacity(0.5) : Theme.stroke).frame(width: 18, height: 1)
                }
            }
        }
    }
}
