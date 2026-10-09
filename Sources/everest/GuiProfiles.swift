import AppKit
import SwiftUI

extension ProfileConfig {
    var tint: Color { Color(hex: UInt32(color, radix: 16) ?? 0x8B5CF6) }
}

/// Coloured badge for a profile.
struct ProfileBadge: View {
    let profile: ProfileConfig
    var size: CGFloat = 26
    var body: some View { IconBadge(icon: profile.symbol, tint: profile.tint, size: size) }
}

// MARK: - Sidebar switcher

struct ProfileSwitcher: View {
    @ObservedObject var model: EverestModel
    @State private var hovering = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                if let p = model.activeProfile { ProfileBadge(profile: p, size: 28) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("profiles.header", model.config.selectedProfile)).font(.ui(9.5, .bold)).tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)
                    Text(model.activeProfile?.title ?? "—").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.ui(10, .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering || open ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .trailing) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("profiles.keyboardProfiles")).font(.ui(10, .bold)).tracking(0.8).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(model.profiles) { p in
                let active = p.id == model.config.selectedProfile
                Button {
                    model.switchProfile(to: p.id)
                    open = false
                } label: {
                    HStack(spacing: 10) {
                        ProfileBadge(profile: p, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text)
                            Text(p.apps.isEmpty ? tr("profiles.slot", p.id) : p.apps.map(\.name).joined(separator: ", "))
                                .font(.ui(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        Spacer()
                        if active { Image(systemName: "checkmark").font(.ui(11, .bold)).foregroundStyle(p.tint) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.white.opacity(0.07) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            HStack {
                if model.canAddProfile {
                    Button {
                        model.addProfile()
                        open = false
                    } label: { Label(tr("common.add"), systemImage: "plus") }
                        .buttonStyle(.compact())
                }
                Spacer()
                Button {
                    model.section = .profiles
                    open = false
                } label: { Label(tr("profiles.manage"), systemImage: "slider.horizontal.3") }
                    .buttonStyle(.compact())
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Page

struct ProfilesPage: View {
    @ObservedObject var model: EverestModel
    @State private var editing: Int?
    private var tint: Color { Section.profiles.tint }

    var body: some View {
        VStack(spacing: 18) {
            Card(tr("profiles.autoSwitch"), subtitle: tr("profiles.autoSwitchNote"),
                 icon: "wand.and.rays", tint: tint) {
                HStack(spacing: 18) {
                    Toggle(isOn: Binding(get: { model.config.autoSwitch },
                                         set: { model.config.autoSwitch = $0; model.persist() })) {
                        Text(tr("profiles.enable")).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    }
                    .toggleStyle(.switch)
                    Divider().frame(height: 20)
                    Text(tr("profiles.otherwise")).font(.ui(12.5)).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: Binding(get: { model.config.defaultProfile },
                                                  set: { model.config.defaultProfile = $0; model.persist() })) {
                        ForEach(model.profiles) { p in Text(p.title).tag(p.id) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Spacer()
                }
                Caption(tr("profiles.autoSwitchHint"),
                        icon: "info.circle")
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                ForEach(model.profiles) { p in profileCard(p) }
                if model.canAddProfile { addCard }
            }

            Caption(tr("profiles.hardwareNote"),
                    icon: "memorychip")
        }
        .sheet(item: Binding(get: { editing.map { EditTarget(id: $0) } }, set: { editing = $0?.id })) { t in
            ProfileEditor(model: model, id: t.id)
        }
    }

    private struct EditTarget: Identifiable { let id: Int }

    private func profileCard(_ p: ProfileConfig) -> some View {
        let active = p.id == model.config.selectedProfile
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProfileBadge(profile: p, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                    Text(tr("profiles.slotOfKeyboard", p.id)).font(.ui(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if active { Pill(text: tr("common.active"), icon: "checkmark", tint: Theme.success) }
            }
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    let b = i < p.buttons.count ? p.buttons[i] : nil
                    VStack(spacing: 4) {
                        KeyScreen(image: b?.iconPath.flatMap { NSImage(contentsOfFile: $0) }, label: "D\(i + 1)", size: 40,
                                  uploading: active && model.keyUpload?.button == i ? model.keyUpload?.progress : nil)
                        Text(b?.title ?? "D\(i + 1)").font(.ui(9.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                infoRow("light.max", lightingLabel(p))
                infoRow("circle.circle", p.dialMode.map { tr("profiles.dialMode", DisplaysPage.modeTitle($0)) } ?? tr("profiles.dialUnchanged"))
                HStack(spacing: 6) {
                    Image(systemName: "app.badge").font(.ui(11)).foregroundStyle(Theme.textTertiary).frame(width: 16)
                    if p.apps.isEmpty {
                        Text(tr("profiles.noLinkedApp")).font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(p.apps.prefix(6), id: \.bundleID) { app in
                            Image(nsImage: AppIcons.icon(forFile: app.path)).resizable()
                                .frame(width: 18, height: 18).help(app.name)
                        }
                        if p.apps.count > 6 {
                            Text("+\(p.apps.count - 6)").font(.ui(11)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if !active {
                    Button { model.switchProfile(to: p.id) } label: { Label(tr("profiles.enable"), systemImage: "power") }
                        .buttonStyle(.primary(p.tint))
                }
                Button { editing = p.id } label: { Label(tr("common.edit"), systemImage: "pencil") }
                    .buttonStyle(.secondary)
                Spacer()
                if model.profiles.count > 1 {
                    IconButton(icon: "trash", help: tr("profiles.deleteHelp"), tint: Theme.danger) {
                        model.deleteProfile(p.id)
                    }
                }
            }
        }
        .padding(18)
        .background(SurfaceBackground(fill: active ? p.tint.opacity(0.07) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(active ? p.tint.opacity(0.7) : .clear, lineWidth: 1.5))
    }

    private func infoRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.ui(11)).foregroundStyle(Theme.textTertiary).frame(width: 16)
            Text(text).font(.ui(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private func lightingLabel(_ p: ProfileConfig) -> String {
        guard let l = p.lighting else { return tr("profiles.keyboardLighting") }
        return l.source == .firmware ? tr("profiles.lightingFirmware", l.firmware.effect.title) : tr("profiles.lightingMac", l.mac.kind.title)
    }

    private var addCard: some View {
        Button { model.addProfile() } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(tr("menu.newProfile")).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text(tr("profiles.freeSlots", ProfileSwitch.maxProfiles - model.profiles.count))
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 250)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(Theme.strokeStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

struct ProfileEditor: View {
    @ObservedObject var model: EverestModel
    let id: Int
    @Environment(\.dismiss) private var dismiss
    @State private var pickingApp = false
    @State private var search = ""
    @State private var apps: [InstalledApp] = []

    private let symbols = ["keyboard", "chevron.left.forwardslash.chevron.right", "music.note", "waveform",
                           "gamecontroller.fill", "paintbrush.pointed.fill", "camera.fill", "film",
                           "briefcase.fill", "house.fill", "bolt.fill", "moon.fill", "headphones", "pencil.and.ruler.fill"]
    private let colors = ["8b5cf6", "ec4899", "f43f5e", "f97316", "f59e0b", "10b981", "06b6d4", "3b82f6", "64748b"]

    private var profile: ProfileConfig? { model.config.profileIndex(id).map { model.config.profiles[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let p = profile {
                HStack(spacing: 14) {
                    ProfileBadge(profile: p, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("profile.defaultName", p.id)).font(.ui(17, .bold)).foregroundStyle(Theme.text)
                        Text(tr("profiles.slotOfKeyboard", p.id)).font(.ui(12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    IconButton(icon: "xmark", help: tr("common.close")) { dismiss() }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("common.name"))
                            StyledField(placeholder: tr("profiles.namePlaceholder"), text: Binding(
                                get: { p.title }, set: { v in model.updateProfile(id) { $0.name = v } }))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("profiles.iconAndColour"))
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 14), spacing: 8) {
                                ForEach(symbols, id: \.self) { s in
                                    Button { model.updateProfile(id) { $0.symbol = s } } label: {
                                        Image(systemName: s).font(.ui(13, .semibold))
                                            .foregroundStyle(p.symbol == s ? .white : Theme.textSecondary)
                                            .frame(width: 34, height: 34)
                                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(p.symbol == s ? AnyShapeStyle(Theme.gradient(p.tint)) : AnyShapeStyle(Theme.surfaceSunken)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 10) {
                                ForEach(colors, id: \.self) { c in
                                    let rgb = RGB(hex: c) ?? .white
                                    ColorDot(color: rgb, size: 22, selected: p.color == c) {
                                        model.updateProfile(id) { $0.color = c }
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("profiles.dialOnActivate"))
                            Picker("", selection: Binding(get: { p.dialMode ?? "" },
                                                          set: { v in model.updateProfile(id) { $0.dialMode = v.isEmpty ? nil : v } })) {
                                Text(tr("profiles.dontChange")).tag("")
                                ForEach(DisplaysPage.modes, id: \.0) { m in Text(m.1).tag(m.0.rawValue) }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            FieldLabel(tr("profiles.linkedApps"), value: p.apps.isEmpty ? nil : "\(p.apps.count)")
                            ForEach(p.apps, id: \.bundleID) { app in
                                HStack(spacing: 10) {
                                    Image(nsImage: AppIcons.icon(forFile: app.path)).resizable()
                                        .frame(width: 26, height: 26)
                                    Text(app.name).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
                                    Spacer()
                                    IconButton(icon: "minus", help: tr("common.remove"), tint: Theme.danger) {
                                        model.unlinkApp(app.bundleID, from: id)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
                            }
                            appPicker
                        }
                        Caption(tr("profiles.keysNote"),
                                icon: "info.circle")
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .padding(22)
        .frame(width: 640, height: 640)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $pickingApp, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result { model.linkApp(url, to: id) }
        }
    }

    private var filtered: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let linked = Set(profile?.apps.map(\.path) ?? [])
        let list = apps.filter { !linked.contains($0.url.path) }
        return q.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StyledField(placeholder: tr("profiles.addApp"), text: $search, icon: "plus.magnifyingglass")
                Button { pickingApp = true } label: { Label(tr("common.other"), systemImage: "folder") }.buttonStyle(.secondary)
            }
            if !search.isEmpty {
                VStack(spacing: 2) {
                    ForEach(filtered.prefix(6)) { app in
                        Button {
                            model.linkApp(app.url, to: id)
                            search = ""
                        } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: AppIcons.icon(forFile: app.url.path)).resizable()
                                    .frame(width: 22, height: 22)
                                Text(app.name).font(.ui(12.5)).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(profile?.tint ?? Theme.accent)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceRaised))
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
}
