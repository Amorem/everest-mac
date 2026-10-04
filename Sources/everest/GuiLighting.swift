import SwiftUI

struct LightingPage: View {
    @ObservedObject var model: EverestModel

    private var tint: Color { Section.lighting.tint }

    var body: some View {
        VStack(spacing: 18) {
            // Live board
            VStack(spacing: 0) {
                HStack {
                    Segmented(items: [
                        .init(value: LightingConfig.Source.firmware, title: tr("menu.keyboardEffects"), icon: "cpu"),
                        .init(value: LightingConfig.Source.mac, title: tr("menu.macEffects"), icon: "sparkles"),
                    ], selection: Binding(
                        get: { model.source },
                        set: { newValue in
                            if newValue == .firmware { model.applyFirmwareNow() } else { model.selectEffect(model.effect.kind) }
                        }), tint: tint)
                    Spacer()
                    Caption(model.source == .firmware
                            ? tr("lighting.byKeyboard")
                            : tr("lighting.byMac"),
                            icon: model.source == .firmware ? "checkmark.seal" : "info.circle")
                }
                .padding([.horizontal, .top], 16)
                KeyboardHero(model: model, height: 320,
                             paintable: model.source == .mac && model.effect.kind == .solid && model.painting)
                    .padding(.bottom, 10)
            }
            .background(SurfaceBackground(radius: 18))

            HStack(alignment: .top, spacing: 18) {
                Group {
                    if model.source == .firmware { firmwareGallery } else { macGallery }
                }
                .frame(maxWidth: .infinity)
                Group {
                    if model.source == .firmware {
                        FirmwareInspector(model: model)
                    } else {
                        MacInspector(model: model)
                    }
                }
                .frame(width: 320)
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 240), spacing: 12)]

    private var firmwareGallery: some View {
        Card(tr("lighting.officialEffects"), subtitle: tr("lighting.officialNote"),
             icon: "cpu", tint: tint) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(FirmwareLighting.Effect.allCases, id: \.self) { e in
                    EffectTile(title: e.title, subtitle: e.blurb, icon: e.icon, tint: tint,
                               selected: model.firmwareLighting.effect == e) {
                        FirmwarePreview(lighting: firmwarePreview(e))
                    } action: {
                        model.selectFirmware(e)
                    }
                }
            }
        }
    }

    private func firmwarePreview(_ e: FirmwareLighting.Effect) -> FirmwareLighting {
        var fw = model.firmwareLighting
        fw.effect = e
        return fw
    }

    private func macPreview(_ k: LedEffect.Kind) -> LedEffect {
        var e = model.effect
        e.kind = k
        if k != .solid { e.perKey = [:] }
        return e
    }

    private var macGallery: some View {
        Card(tr("menu.macEffects"), subtitle: tr("lighting.macNote"),
             icon: "sparkles", tint: tint) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(LedEffect.Kind.allCases, id: \.self) { k in
                    EffectTile(title: k.title, subtitle: nil, icon: k.icon, tint: tint,
                               selected: model.effect.kind == k) {
                        EffectPreview(effect: macPreview(k))
                    } action: {
                        model.selectEffect(k)
                    }
                }
            }
        }
    }
}

// MARK: - Tile

struct EffectTile<Preview: View>: View {
    var title: String
    var subtitle: String?
    var icon: String
    var tint: Color
    var selected: Bool
    @ViewBuilder var preview: Preview
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.55))
                    preview.padding(7)
                }
                .frame(height: 64)
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.ui(11, .semibold))
                        .foregroundStyle(selected ? tint : Theme.textSecondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).font(.ui(10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.ui(13)).foregroundStyle(tint)
                    }
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? tint.opacity(0.10) : (hovering ? Color.white.opacity(0.06) : Theme.surfaceRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.85) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: selected ? tint.opacity(0.28) : .clear, radius: 12)
            .scaleEffect(hovering && !selected ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Firmware inspector

struct FirmwareInspector: View {
    @ObservedObject var model: EverestModel
    private var fw: FirmwareLighting { model.firmwareLighting }
    private var tint: Color { Section.lighting.tint }

    var body: some View {
        Card(fw.effect.title, subtitle: fw.effect.blurb, icon: fw.effect.icon, tint: tint) {
            VStack(alignment: .leading, spacing: 18) {
                if fw.effect == .off {
                    Caption(tr("lighting.offNote"))
                } else {
                    colours
                    if fw.effect.hasSpeed {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("lighting.speed"), value: "\(fw.speedLevel + 1) / 5")
                            GlowSlider(value: binding(\.speed), range: 0...100, step: 25, tint: tint,
                                       ticks: [tr("lighting.slow"), "", "", "", tr("lighting.fast")])
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel(tr("lighting.brightness"), value: "\(Int(fw.brightness)) %")
                        GlowSlider(value: binding(\.brightness), range: 0...100, step: 5, tint: tint)
                    }
                    if fw.effect == .wave {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("lighting.direction"))
                            Segmented(items: [
                                .init(value: FirmwareLighting.Direction.right, title: "", icon: "arrow.right"),
                                .init(value: .left, title: "", icon: "arrow.left"),
                                .init(value: .down, title: "", icon: "arrow.down"),
                                .init(value: .up, title: "", icon: "arrow.up"),
                            ], selection: binding(\.direction), tint: tint, fill: true)
                        }
                    }
                    if fw.effect == .tornado {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("lighting.rotation"))
                            Segmented(items: [
                                .init(value: true, title: tr("lighting.clockwise"), icon: "arrow.clockwise"),
                                .init(value: false, title: tr("lighting.counterclockwise"), icon: "arrow.counterclockwise"),
                            ], selection: binding(\.clockwise), tint: tint, fill: true)
                        }
                    }
                }
                Divider().overlay(Theme.stroke)
                HStack {
                    Caption(tr("lighting.savedInProfile"), icon: "internaldrive")
                    Spacer()
                    Button { model.applyFirmwareNow() } label: {
                        Label(tr("lighting.reapply"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.compact())
                }
            }
        }
    }

    @ViewBuilder private var colours: some View {
        let modes = fw.effect.modes
        VStack(alignment: .leading, spacing: 12) {
            if modes.count > 1 {
                FieldLabel(tr("lighting.colors"))
                ChipGrid(items: modes.map { ($0, $0.title) },
                         selection: Binding(get: { fw.effectiveMode },
                                            set: { m in model.updateFirmware { $0.mode = m } }),
                         tint: tint)
            }
            switch fw.effectiveMode {
            case .rainbow:
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.spectrum)
                    .frame(height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
                Caption(tr("lighting.allHues"))
            case .single:
                dots([(0, tr("lighting.colour"))])
            case .dual:
                dots([(0, tr("lighting.colour1")), (1, tr("lighting.colour2"))])
            case .quad:
                dots([(0, "1"), (1, "2"), (2, "3"), (3, "4")])
            case .withBackground:
                dots([(0, tr("lighting.keyColour")), (1, tr("lighting.backgroundColour"))])
            }
        }
    }

    private func dots(_ items: [(Int, String)]) -> some View {
        HStack(spacing: 18) {
            ForEach(items, id: \.0) { item in
                ColorDot(color: fw.color(item.0), size: 36, label: item.1) {
                    model.editColor(.firmware(item.0))
                }
            }
            Spacer()
        }
    }

    private func binding<T>(_ path: WritableKeyPath<FirmwareLighting, T>) -> Binding<T> {
        Binding(get: { model.firmwareLighting[keyPath: path] },
                set: { v in model.updateFirmware { $0[keyPath: path] = v } })
    }
}

// MARK: - Mac inspector

struct MacInspector: View {
    @ObservedObject var model: EverestModel
    private var e: LedEffect { model.effect }
    private var tint: Color { Section.lighting.tint }

    var body: some View {
        Card(e.kind.title, subtitle: model.playing ? tr("lighting.runningOnKeyboard") : tr("lighting.paused"),
             icon: e.kind.icon, tint: tint) {
            VStack(alignment: .leading, spacing: 18) {
                if e.kind == .off {
                    Caption(tr("lighting.ledsBlack"))
                } else {
                    if e.kind == .solid { painter }
                    if e.usesPalette { palette }
                    if e.kind == .fire {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: ["5a0000", "e01b00", "ff7a00", "ffc23a", "fff1c4"]
                                .compactMap { RGB(hex: $0) }.map { Color(rgb: $0) }, startPoint: .leading, endPoint: .trailing))
                            .frame(height: 12)
                        Caption(tr("lighting.flameNote"))
                    }
                    if e.kind == .rainbow {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.spectrum).frame(height: 12)
                    }
                    if e.usesSpeed {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("lighting.speed"), value: speedLabel)
                            GlowSlider(value: binding(\.speed), range: 1...100, tint: tint,
                                       ticks: [tr("lighting.slow"), tr("lighting.normal"), tr("lighting.fast")])
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel(tr("lighting.brightness"), value: "\(Int(e.brightness)) %")
                        GlowSlider(value: binding(\.brightness), range: 0...100, step: 1, tint: tint)
                    }
                    if e.usesDirection {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel(tr("lighting.direction"))
                            Segmented(items: [
                                .init(value: 0, title: "", icon: "arrow.right"),
                                .init(value: 4, title: "", icon: "arrow.left"),
                                .init(value: 2, title: "", icon: "arrow.down"),
                                .init(value: 6, title: "", icon: "arrow.up"),
                                .init(value: 8, title: "", icon: "smallcircle.filled.circle"),
                            ], selection: binding(\.direction), tint: tint, fill: true)
                        }
                    }
                }
                Divider().overlay(Theme.stroke)
                HStack(spacing: 8) {
                    Button { model.togglePlayback() } label: {
                        Label(model.playing ? tr("live.pause") : tr("live.start"), systemImage: model.playing ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.primary(tint))
                    Button { model.saveStaticToKeyboard() } label: {
                        Label(tr("lighting.freeze"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.secondary)
                    .help(tr("lighting.freezeNote"))
                }
            }
        }
    }

    private var speedLabel: String {
        let f = pow(2, (e.speed - 50) / 25)
        return String(format: "×%.2g", f)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldLabel(tr("lighting.palette"), value: tr(e.palette.count > 1 ? "lighting.colourCount.other" : "lighting.colourCount.one", e.palette.count))
            HStack(spacing: 12) {
                ForEach(Array(e.palette.enumerated()), id: \.offset) { i, c in
                    ColorDot(color: c, size: 30) { model.editColor(.palette(i)) }
                        .contextMenu {
                            Button(tr("lighting.editEllipsis")) { model.editColor(.palette(i)) }
                            if e.palette.count > 1 {
                                Button(tr("common.delete")) { model.removePaletteColor(i) }
                            }
                        }
                }
                if e.palette.count < 8 {
                    Button { model.addPaletteColor() } label: {
                        Image(systemName: "plus")
                            .font(.ui(12, .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                                .foregroundStyle(Theme.strokeStrong))
                    }
                    .buttonStyle(.plain)
                    .help(tr("lighting.addColour"))
                }
                Spacer(minLength: 0)
            }
            Caption(tr("lighting.rightClickHint"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(PalettePreset.all) { preset in
                    PresetChip(preset: preset, selected: preset.colors == e.palette) {
                        model.applyPalettePreset(preset.colors)
                    }
                }
            }
        }
    }

    private var painter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.painting) {
                Text(tr("lighting.paintKeys")).font(.ui(12.5, .medium)).foregroundStyle(Theme.text)
            }
            .toggleStyle(.switch)
            .tint(tint)
            if model.painting {
                HStack(spacing: 12) {
                    ColorDot(color: model.brush, size: 30, selected: true) { model.editColor(.brush) }
                    Caption(tr("lighting.paintHint"))
                    Spacer(minLength: 0)
                }
                HStack {
                    ForEach(["ffffff", "ff2d55", "ff9500", "ffd60a", "34c759", "00c7be", "0a84ff", "bf5af2"], id: \.self) { hex in
                        let c = RGB(hex: hex)!
                        ColorDot(color: c, size: 18, selected: model.brush == c) { model.brush = c }
                    }
                }
                Button { model.clearPainting() } label: { Label(tr("lighting.clearAll"), systemImage: "eraser") }
                    .buttonStyle(.compact())
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<LedEffect, T>) -> Binding<T> {
        Binding(get: { model.effect[keyPath: path] },
                set: { v in model.updateEffect { $0[keyPath: path] = v } })
    }
}

struct PresetChip: View {
    let preset: PalettePreset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                LinearGradient(colors: preset.colors.map { Color(rgb: $0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(preset.name).font(.ui(10.5, .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.07) : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.6) : Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
