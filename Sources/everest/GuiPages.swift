import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Displays

struct DisplaysPage: View {
    @ObservedObject var model: EverestModel
    @State private var pickingDial = false
    @State private var appearance: AppearanceTarget?
    private var tint: Color { Section.displays.tint }

    static var modes: [(Proto.MainMode, String, String)] { [
        (.clock, tr("mode.clock"), "clock.fill"), (.image, tr("mode.image"), "photo.fill"),
        (.volume, tr("mode.volume"), "speaker.wave.2.fill"), (.cpu, "CPU", "cpu"),
        (.gpu, "GPU", "square.stack.3d.up.fill"), (.ram, "RAM", "memorychip.fill"),
        (.hd, tr("mode.disk"), "internaldrive.fill"), (.network, tr("mode.network"), "network"),
    ] }

    static func modeTitle(_ raw: String) -> String {
        modes.first { $0.0.rawValue == raw }?.1 ?? raw.capitalized
    }

    var body: some View {
        VStack(spacing: 18) {
            Card(tr("device.dial"), subtitle: tr("displays.dial.subtitle"), icon: "circle.circle", tint: tint) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(tint.opacity(0.18)).blur(radius: 40).frame(width: 220, height: 220)
                            DialBezel(size: 210) {
                                DialFace(mode: Proto.MainMode(rawValue: model.config.mainDisplayMode) ?? .clock,
                                         clockStyle: model.config.clockStyle, image: model.dialImage)
                            }
                        }
                        Text(Self.modeTitle(model.config.mainDisplayMode))
                            .font(.ui(13, .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 240)

                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            FieldLabel(tr("displays.display"))
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                                ForEach(Self.modes, id: \.0) { m in
                                    ModeTile(title: m.1, icon: m.2, tint: tint,
                                             selected: model.config.mainDisplayMode == m.0.rawValue) {
                                        model.setDialMode(m.0, label: m.1)
                                    }
                                }
                            }
                            Caption(tr("displays.metricsNote"))
                        }

                        if model.config.mainDisplayMode == "clock" {
                            VStack(alignment: .leading, spacing: 10) {
                                FieldLabel(tr("mode.clock"))
                                HStack(spacing: 10) {
                                    Segmented(items: [.init(value: "analog", title: tr("clock.analog"), icon: "clock"),
                                                      .init(value: "digital", title: tr("clock.digital"), icon: "textformat.123")],
                                              selection: $model.config.clockStyle, tint: tint)
                                    Segmented(items: [.init(value: "24h", title: "24 h"), .init(value: "12h", title: "12 h")],
                                              selection: $model.config.clockFormat, tint: tint)
                                    Spacer()
                                    Button { model.syncClock() } label: {
                                        Label(tr("clock.sync"), systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .buttonStyle(.primary(tint))
                                }
                            }
                        }

                        if model.config.mainDisplayMode == "image" {
                            VStack(alignment: .leading, spacing: 10) {
                                FieldLabel(tr("mode.image"))
                                HStack(spacing: 10) {
                                    Button { pickingDial = true } label: { Label(tr("displays.chooseImage"), systemImage: "photo") }
                                        .buttonStyle(.primary(tint))
                                    Button {
                                        model.runDevice(tr("reset.title")) { kb in
                                            kb.resetDial()
                                            return tr("displays.logoRestored")
                                        }
                                    } label: { Label(tr("displays.factoryLogo"), systemImage: "arrow.uturn.backward") }
                                        .buttonStyle(.secondary)
                                }
                                Caption(tr("displays.imageCropped"), icon: "crop")
                            }
                        }
                    }
                }
            }

            Card(tr("displays.keys.title"), subtitle: tr("displays.keys.subtitle"),
                 icon: "square.grid.2x2.fill", tint: Section.buttons.tint) {
                HStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { i in
                        VStack(spacing: 10) {
                            KeyScreen(image: model.displayImages[i], label: "D\(i + 1)", size: 84,
                                      uploading: model.keyUpload?.button == i ? model.keyUpload?.progress : nil)
                            Text(model.config.buttons[i].title ?? "D\(i + 1)")
                                .font(.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            HStack(spacing: 6) {
                                Button(tr("displays.change")) { appearance = AppearanceTarget(target: .dkey(i)) }.buttonStyle(.compact(.primary))
                                IconButton(icon: "arrow.uturn.backward", help: tr("displays.factoryIcon")) { model.resetButtonIcon(i) }
                                    .disabled(model.keysBusy)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
                    }
                }
                Caption(tr("displays.imagesResized"), icon: "crop")
            }
        }
        .fileImporter(isPresented: $pickingDial, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.uploadDialImage(url: url) }
        }
        .sheet(item: $appearance) { t in KeyAppearanceSheet(model: model, target: t.target, tab: t.tab) }
    }
}

struct ModeTile: View {
    let title: String
    let icon: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.ui(17, .semibold))
                    .foregroundStyle(selected ? .white : tint)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(selected ? AnyShapeStyle(Theme.gradient(tint)) : AnyShapeStyle(tint.opacity(0.12))))
                Text(title).font(.ui(11.5, .semibold)).foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? tint.opacity(0.10) : (hovering ? Color.white.opacity(0.06) : Theme.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? tint.opacity(0.8) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

/// Which key the appearance sheet is open for, and on which tab.
struct AppearanceTarget: Identifiable {
    let target: KeyTarget
    var tab: KeyAppearanceSheet.Tab = .presets
    var id: KeyTarget { target }
}

struct ButtonsPage: View {
    @ObservedObject var model: EverestModel
    @State private var appearance: AppearanceTarget?
    private var tint: Color { Section.buttons.tint }


    var body: some View {
        VStack(spacing: 18) {
            if !model.accessibilityOK {
                AccessibilityBanner(model: model)
            }
            if !model.daemonRunning {
                DaemonStoppedBanner(model: model, note: tr("buttons.daemonStoppedNote"))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    ButtonEditorCard(model: model, target: .dkey(i), appearance: $appearance)
                }
            }

            Card(tr("buttons.flashMemory"), subtitle: tr("buttons.flashMemoryNote"),
                 icon: "memorychip", tint: tint) {
                HStack {
                    Caption(tr("buttons.accessibilityNote"),
                            icon: "hand.raised")
                    Spacer()
                    Button { model.clearFlashActions() } label: { Label(tr("buttons.clearLeftovers"), systemImage: "eraser") }
                        .buttonStyle(.secondary)
                }
            }
        }
        .sheet(item: $appearance) { t in KeyAppearanceSheet(model: model, target: t.target, tab: t.tab) }
    }
}

extension ActionKind {
    var icon: String {
        switch self {
        case .shell: return "terminal.fill"
        case .url: return "link"
        case .app: return "app.dashed"
        case .open: return "folder.fill"
        case .keypress: return "command"
        case .text: return "text.cursor"
        case .profile: return "square.stack.3d.up.fill"
        case .night: return "moon.fill"
        case .noAction: return "nosign"
        }
    }

    var title: String {
        switch self {
        case .shell: return tr("action.shell")
        case .url: return tr("action.url")
        case .app: return tr("action.app")
        case .open: return tr("action.open")
        case .keypress: return tr("action.keypress")
        case .text: return tr("action.text")
        case .profile: return tr("action.profile")
        case .night: return tr("action.night")
        case .noAction: return tr("action.none")
        }
    }

    var placeholder: String {
        switch self {
        case .shell: return "open -a Terminal"
        case .url: return "https://…"
        case .open: return "~/Documents"
        case .keypress: return "cmd+shift+4 · mute · playpause"
        case .text: return tr("action.textToType")
        case .app, .profile, .night, .noAction: return ""
        }
    }
}

/// The daemon runs every key action; without it the keys do nothing.
struct DaemonStoppedBanner: View {
    @ObservedObject var model: EverestModel
    let note: String

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(icon: "bolt.fill", tint: Theme.amber, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("buttons.daemonStopped")).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(note)
                    .font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { model.toggleDaemon() } label: { Label(tr("common.start"), systemImage: "play.fill") }
                .buttonStyle(.primary(Theme.amber))
        }
        .padding(14)
        .background(SurfaceBackground(fill: Theme.amber.opacity(0.07)))
    }
}

/// Name, picture and action of one screen key: D1–D4 on the keyboard or one
/// of the DisplayPad's twelve.
struct ButtonEditorCard: View {
    @ObservedObject var model: EverestModel
    let target: KeyTarget
    @Binding var appearance: AppearanceTarget?
    private var tint: Color { target.tint }

    var body: some View {
        let button = model.button(target)
        let action = button.action
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button { appearance = AppearanceTarget(target: target) } label: {
                    KeyScreen(image: model.image(for: target), label: target.label, size: 64,
                              uploading: model.uploading(target), factory: !target.isPad)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "photo.badge.plus")
                                .font(.ui(10, .bold)).foregroundStyle(.white)
                                .padding(4).background(Circle().fill(tint))
                                .offset(x: 4, y: 4)
                        }
                }
                .buttonStyle(.plain)
                .help(tr("buttons.pickPresetAppImage", target.label))
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("buttons.keyHeader", target.label)).font(.ui(10.5, .bold)).tracking(0.8).foregroundStyle(tint)
                    StyledField(placeholder: tr("common.name"), text: Binding(
                        get: { model.button(target).title ?? "" },
                        set: { model.setButton(target, name: $0) }))
                }
            }
            Segmented(items: ActionKind.allCases.map { .init(value: $0, title: "", icon: $0.icon, help: $0.title) },
                      selection: Binding(get: { action.type }, set: { model.setButton(target, type: $0) }),
                      tint: tint, fill: true)
            if action.type == .profile {
                profileRow(value: action.value)
            } else if action.type == .app {
                appRow(path: action.value)
            } else if action.type == .night {
                VStack(alignment: .leading, spacing: 8) {
                    Caption(tr("night.note"), icon: "moon.fill")
                    Toggle(isOn: Binding(get: { model.config.nightSleepsDisplays },
                                         set: { model.config.nightSleepsDisplays = $0; model.persist() })) {
                        Text(tr("night.displays")).font(.ui(12)).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.switch)
                    Caption(tr("night.displaysNote"), icon: "lock")
                }
            } else if action.type != .noAction {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(action.type.title)
                    StyledField(placeholder: action.type.placeholder, text: Binding(
                        get: { model.button(target).action.value },
                        set: { model.setButton(target, value: $0) }), icon: action.type.icon, monospaced: action.type != .text)
                }
            } else {
                Caption(tr("buttons.noAction"))
                    .frame(height: 48, alignment: .center)
            }
            HStack {
                Button { appearance = AppearanceTarget(target: target) } label: {
                    Label(tr("buttons.presetsAndIcon"), systemImage: "square.grid.3x3.fill")
                }
                .buttonStyle(.compact())
                Button { model.restoreFactory(target) } label: {
                    Label(tr(target.isPad ? "pad.clearKey" : "buttons.factoryValues"),
                          systemImage: target.isPad ? "eraser" : "arrow.uturn.backward")
                }
                .buttonStyle(.compact(.ghost))
                .disabled(!target.isPad && model.keysBusy)
                .help(tr(target.isPad ? "pad.clearKeyHelp" : "buttons.factoryValuesHelp", target.label))
                Spacer()
                Button {
                    ActionRunner.run(model.button(target).action)
                    model.report(tr("buttons.actionRan", target.label))
                } label: { Label(tr("common.test"), systemImage: "play.fill") }
                    .buttonStyle(.compact(.primary))
                    .disabled(action.type == .noAction)
            }
        }
        .padding(18)
        .background(SurfaceBackground())
    }

    /// Which profile the key switches to: the next or previous one, or a
    /// given profile.
    private func profileRow(value: String) -> some View {
        let options: [(String, String)] = [("next", tr("profileAction.next")), ("previous", tr("profileAction.previous"))]
            + model.profiles.map { ("\($0.id)", $0.title) }
        return HStack(spacing: 10) {
            Image(systemName: ActionKind.profile.icon).font(.system(size: 18)).foregroundStyle(tint)
            Picker("", selection: Binding(get: { options.contains { $0.0 == value } ? value : "next" },
                                          set: { model.setButton(target, value: $0) })) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func appRow(path: String) -> some View {
        let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
        return HStack(spacing: 10) {
            if exists {
                Image(nsImage: AppIcons.icon(forFile: path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
                        .font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                    Text(tr("buttons.appHint")).font(.ui(10.5)).foregroundStyle(Theme.textTertiary)
                }
            } else {
                Image(systemName: "app.dashed").font(.system(size: 22)).foregroundStyle(Theme.textTertiary)
                Text(tr("buttons.noApp")).font(.ui(12.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(tr("common.choose")) { appearance = AppearanceTarget(target: target, tab: .apps) }
                .buttonStyle(.compact())
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: - Layout

struct KeyboardLayoutPage: View {
    @ObservedObject var model: EverestModel
    @State private var currentLayout = "…"
    @State private var installed: [Layout.InputSource] = []
    private var tint: Color { Section.keyboard.tint }
    private var kbLayout: KeyboardLayout { model.layout }

    /// The macOS input source that matches the keycaps, if installed.
    private var suggestion: Layout.InputSource? {
        for want in kbLayout.macInputSources {
            if let s = installed.first(where: { $0.id == want || $0.id == "com.apple.keylayout.\(want)" }) { return s }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 18) {
            Card(tr("keyboard.title"), subtitle: tr("keyboard.titleNote"),
                 icon: "keyboard", tint: tint) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.config.layoutOverride == nil ? tr("keyboard.detected") : tr("keyboard.chosen"))
                            .font(.ui(10, .bold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
                        Text(kbLayout.title).font(.ui(17, .semibold)).foregroundStyle(Theme.text)
                        Text(kbLayout.family == .iso
                             ? tr("keyboard.isoShape")
                             : tr("keyboard.ansiShape"))
                            .font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.config.layoutOverride?.rawValue ?? "auto" },
                        set: { model.setLayoutOverride($0 == "auto" ? nil : KeyboardLayout(rawValue: $0)) })) {
                        Text(tr("keyboard.automatic")).tag("auto")
                        Divider()
                        ForEach(KeyboardLayout.allCases) { l in Text(l.title).tag(l.rawValue) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surfaceRaised))
                if let d = model.detectedLayout, let o = model.config.layoutOverride, d != o {
                    Caption(tr("keyboard.reportsLayout", d.title),
                            icon: "info.circle")
                }
                if kbLayout != .uk {
                    Caption(kbLayout == .us
                            ? tr("keyboard.verifiedNote1")
                            : tr("keyboard.verifiedNote2"),
                            icon: "checkmark.seal")
                }
            }

            Card(tr("keyboard.macLayout"), subtitle: tr("keyboard.macLayoutNote"),
                 icon: "globe", tint: tint) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("keyboard.activeBadge")).font(.ui(10, .bold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
                        Text(currentLayout).font(.ui(17, .semibold)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                    IconButton(icon: "arrow.clockwise", help: tr("common.refresh")) { refresh() }
                    if let s = suggestion {
                        Button {
                            Layout.selectInputSource(named: s.id)
                            refresh()
                            model.report(tr("keyboard.switchedTo", s.name))
                        } label: { Label(tr("keyboard.use", s.name), systemImage: "checkmark") }
                            .buttonStyle(.primary(tint))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surfaceRaised))
                if suggestion == nil {
                    Caption(tr("keyboard.noMacLayout", kbLayout.title),
                            icon: "exclamationmark.triangle")
                }
                if kbLayout == .uk {
                    HStack(spacing: 22) {
                        legend(tr("keyboard.legend.quote"), tr("keyboard.asPrinted"))
                        legend(tr("keyboard.legend.at"), tr("keyboard.legend.rightOfSemicolon"))
                        legend(tr("keyboard.legend.backslash"), tr("keyboard.isoKeyLabel"))
                    }
                }
            }

            if kbLayout.family == .iso {
                Card(tr("keyboard.isoMuteTitle"), subtitle: tr("keyboard.isoMuteNote"),
                     icon: "wrench.and.screwdriver.fill", tint: Theme.orange) {
                    HStack(spacing: 10) {
                        Button {
                            Layout.runHidutil(mapping: [["HIDKeyboardModifierMappingSrc": 0x700000064,
                                                        "HIDKeyboardModifierMappingDst": 0x700000031]])
                            model.report(tr("keyboard.remapApplied"))
                        } label: { Label(tr("keyboard.remapIso"), systemImage: "arrow.left.arrow.right") }
                            .buttonStyle(.primary(Theme.orange))
                        Button {
                            Layout.runHidutil(mapping: [])
                            model.report(tr("keyboard.remapsCleared"))
                        } label: { Label(tr("keyboard.clearRemaps"), systemImage: "trash") }
                            .buttonStyle(.danger)
                        Spacer()
                    }
                    Caption(tr("keyboard.hidutilNote"),
                            icon: "terminal")
                }
            }
        }
        .onAppear { refresh() }
    }

    private func legend(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
            Text(sub).font(.ui(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func refresh() {
        currentLayout = (Layout.currentLayoutID() ?? tr("keyboard.unknown")).replacingOccurrences(of: "com.apple.keylayout.", with: "")
        installed = Layout.inputSources()
    }
}

// MARK: - System

struct SystemPage: View {
    @ObservedObject var model: EverestModel
    private var tint: Color { Section.system.tint }

    private var inApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    var body: some View {
        VStack(spacing: 18) {
            Card(tr("settings.language.title"), subtitle: tr("settings.language.note"),
                 icon: "globe", tint: Theme.sky) {
                HStack {
                    LanguagePicker(model: model).frame(width: 240)
                    Spacer()
                }
            }

            Card(tr("action.app"), subtitle: tr("system.background"),
                 icon: "menubar.rectangle", tint: Theme.violet) {
                VStack(alignment: .leading, spacing: 14) {
                    settingRow(tr("system.launchAtLogin"),
                               tr("system.launchAtLoginNote"),
                               Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    if let note = model.loginItemNote {
                        Caption(note, icon: "exclamationmark.triangle")
                    } else if !inApplications {
                        Caption(tr("system.launchedFrom", Bundle.main.bundlePath),
                                icon: "info.circle")
                    }
                    Divider().overlay(Theme.stroke)
                    settingRow(tr("system.keepRunning"),
                               tr("system.keepRunningNote"),
                               Binding(get: { model.config.keepRunning },
                                       set: { model.config.keepRunning = $0; model.persist() }))
                    Divider().overlay(Theme.stroke)
                    settingRow(tr("system.autoDaemon"),
                               tr("system.autoDaemonNote"),
                               Binding(get: { model.config.daemonEnabled },
                                       set: { _ in model.toggleDaemon() }))
                }
            }

            HStack(alignment: .top, spacing: 18) {
                Card(tr("system.daemonTitle"), subtitle: tr("system.daemonSubtitle"),
                     icon: "bolt.fill", tint: Section.buttons.tint) {
                    HStack(spacing: 10) {
                        StatusDot(on: model.daemonActive, color: Theme.indigo)
                        Text(model.daemonActive ? tr("system.listening") : tr("system.stoppedState"))
                            .font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Button { model.toggleDaemon() } label: {
                            Label(model.daemonRunning ? tr("common.stop") : tr("common.start"),
                                  systemImage: model.daemonRunning ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(model.daemonRunning ? .secondary : .primary(Theme.indigo))
                    }
                    Caption(tr("system.autostartHint"),
                            icon: "terminal")
                }
                Card(tr("system.monitoring"), subtitle: tr("system.monitoringNote"),
                     icon: "chart.xyaxis.line", tint: Theme.emerald) {
                    Toggle(isOn: Binding(get: { model.config.monitorMode },
                                         set: { model.config.monitorMode = $0; model.persist() })) {
                        Text(tr("system.sendMetrics"))
                            .font(.ui(12.5)).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.emerald)
                    Caption(tr("system.metricsEvery"))
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Card(tr("system.keyboardCard"), subtitle: tr("system.keyboardCardNote"), icon: "keyboard", tint: tint) {
                HStack(spacing: 12) {
                    stat(tr("system.modules"), model.attached)
                    stat(tr("device.firmware"), model.firmware)
                    stat(tr("device.dial"), DisplaysPage.modeTitle(model.dialMode))
                    stat(tr("system.lightProfile"), model.source == .firmware ? model.firmwareLighting.effect.title : "Custom (Mac)")
                }
                HStack(spacing: 10) {
                    Button { model.refreshDevice() } label: { Label(tr("common.refresh"), systemImage: "arrow.clockwise") }
                        .buttonStyle(.secondary)
                    Button { model.recover() } label: { Label(tr("system.unlock"), systemImage: "cross.case.fill") }
                        .buttonStyle(.primary(tint))
                    Spacer()
                }
                Caption(tr("system.unlockNote"),
                        icon: "lifepreserver")
            }
        }
    }

    private func settingRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden().tint(Theme.violet)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.ui(9.5, .bold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
            Text(value).font(.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Shown when macOS has not (or no longer) granted Accessibility to Everest:
/// shortcut and typed-text actions are then dropped without any error.
struct AccessibilityBanner: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(icon: "hand.raised.fill", tint: Theme.rose, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("system.noAccessibility")).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(tr("system.noAccessibilityNote"))
                    .font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button { model.openAccessibilitySettings() } label: { Label(tr("system.openSettings"), systemImage: "gearshape") }
                    .buttonStyle(.primary(Theme.rose))
                Button { _ = ActionRunner.accessibilityGranted(prompt: true) } label: { Text(tr("system.askAgain")) }
                    .buttonStyle(.compact())
            }
        }
        .padding(14)
        .background(SurfaceBackground(fill: Theme.rose.opacity(0.07)))
    }
}
