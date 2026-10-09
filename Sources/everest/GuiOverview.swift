import AppKit
import SwiftUI

// MARK: - Dial face

/// What the round dial screen shows, drawn for previews.
struct DialFace: View {
    var mode: Proto.MainMode
    var clockStyle: String = "analog"
    var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Color.black
                switch mode {
                case .image:
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        MountainLogo().padding(d * 0.28)
                    }
                case .clock:
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        if clockStyle == "digital" {
                            DigitalClock(date: ctx.date, size: d)
                        } else {
                            AnalogClock(date: ctx.date)
                        }
                    }
                default:
                    MetricFace(mode: mode, size: d)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct MountainLogo: View {
    var body: some View {
        Image(nsImage: MountainMark.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

struct AnalogClock: View {
    var date: Date
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 * 0.82
            for i in 0..<60 {
                let a = Double(i) / 60 * 2 * .pi
                let long = i % 5 == 0
                let r0 = r * (long ? 0.84 : 0.92)
                var p = Path()
                p.move(to: CGPoint(x: c.x + sin(a) * r0, y: c.y - cos(a) * r0))
                p.addLine(to: CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r))
                ctx.stroke(p, with: .color(.white.opacity(long ? 0.9 : 0.3)), lineWidth: long ? max(1, r * 0.035) : 0.6)
            }
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let s = Double(comps.second ?? 0), m = Double(comps.minute ?? 0) + s / 60
            let h = Double((comps.hour ?? 0) % 12) + m / 60
            func hand(_ angle: Double, _ len: Double, _ width: CGFloat, _ color: Color) {
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + sin(angle) * r * len, y: c.y - cos(angle) * r * len))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand(h / 12 * 2 * .pi, 0.5, max(1.5, r * 0.06), .white)
            hand(m / 60 * 2 * .pi, 0.75, max(1.2, r * 0.04), .white)
            hand(s / 60 * 2 * .pi, 0.82, max(0.8, r * 0.015), Color(hex: 0xFF4D6D))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(.white))
        }
    }
}

struct DigitalClock: View {
    var date: Date
    var size: CGFloat
    var body: some View {
        VStack(spacing: size * 0.02) {
            Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: size * 0.22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: size * 0.075, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct MetricFace: View {
    var mode: Proto.MainMode
    var size: CGFloat

    private var info: (String, String, Color, Double) {
        switch mode {
        case .volume: return ("speaker.wave.2.fill", tr("metric.volume"), Theme.sky, 0.6)
        case .cpu: return ("cpu", "CPU", Theme.emerald, 0.34)
        case .gpu: return ("square.stack.3d.up.fill", "GPU", Theme.violet, 0.22)
        case .hd: return ("internaldrive.fill", tr("metric.disk"), Theme.amber, 0.58)
        case .network: return ("network", tr("metric.network"), Theme.cyan, 0.15)
        case .ram: return ("memorychip.fill", "RAM", Theme.pink, 0.66)
        default: return ("gauge.medium", "APM", Theme.orange, 0.4)
        }
    }

    var body: some View {
        let (icon, label, color, v) = info
        ZStack {
            Circle().trim(from: 0.1, to: 0.9)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(size * 0.14)
            Circle().trim(from: 0.1, to: 0.1 + 0.8 * v)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(size * 0.14)
                .shadow(color: color.opacity(0.7), radius: size * 0.04)
            VStack(spacing: size * 0.02) {
                Image(systemName: icon).font(.system(size: size * 0.12, weight: .semibold)).foregroundStyle(color)
                Text("\(Int(v * 100))%").font(.system(size: size * 0.16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(label).font(.system(size: size * 0.06, weight: .bold)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        VStack(spacing: 18) {
            // Hero
            VStack(spacing: 0) {
                KeyboardHero(model: model, height: 360)
                    .padding(.top, 8)
                HStack(spacing: 10) {
                    Pill(text: model.attached, icon: "keyboard", tint: Theme.textSecondary)
                    Pill(text: model.layout.title, icon: "globe", tint: Theme.textSecondary)
                    Spacer()
                    Button { model.section = .lighting } label: {
                        Label(tr("overview.changeLighting"), systemImage: "light.max")
                    }
                    .buttonStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            .background(SurfaceBackground(radius: 18))

            HStack(alignment: .top, spacing: 18) {
                lightingTile
                dialTile
                buttonsTile
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lightingTile: some View {
        Card(tr("lighting.title"), subtitle: model.source == .firmware ? tr("overview.keyboardEffect") : tr("overview.macEffect"),
             icon: Section.lighting.icon, tint: Section.lighting.tint) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.5))
                    if model.source == .firmware {
                        FirmwarePreview(lighting: model.firmwareLighting).padding(8)
                    } else {
                        EffectPreview(effect: model.effect).padding(8)
                    }
                }
                .frame(height: 76)
                HStack {
                    Text(model.source == .firmware ? model.firmwareLighting.effect.title : model.effect.kind.title)
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button(tr("common.edit")) { model.section = .lighting }.buttonStyle(.compact())
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var dialTile: some View {
        Card(tr("device.dial"), subtitle: tr("overview.dialSubtitle"), icon: Section.displays.icon, tint: Section.displays.tint) {
            HStack(spacing: 14) {
                DialBezel(size: 92) {
                    DialFace(mode: Proto.MainMode(rawValue: model.config.mainDisplayMode) ?? .clock,
                             clockStyle: model.config.clockStyle, image: model.dialImage)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(DisplaysPage.modeTitle(model.config.mainDisplayMode))
                        .font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                    Button(tr("common.configure")) { model.section = .displays }.buttonStyle(.compact())
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var buttonsTile: some View {
        Card(tr("section.buttons.title"), subtitle: model.daemonActive ? tr("overview.actionsActive") : tr("daemon.stopped"),
             icon: Section.buttons.icon, tint: Section.buttons.tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { i in
                        VStack(spacing: 5) {
                            KeyScreen(image: model.displayImages[i], label: "D\(i + 1)", size: 44,
                                      uploading: model.keyUpload?.button == i ? model.keyUpload?.progress : nil)
                            Text(model.config.buttons[i].title ?? "D\(i + 1)")
                                .font(.ui(10, .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Spacer()
                    Button(tr("common.configure")) { model.section = .buttons }.buttonStyle(.compact())
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Round bezel around a dial preview.
struct DialBezel<Content: View>: View {
    var size: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x4A4E57), Color(hex: 0x1E2025), Color(hex: 0x3A3D45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.5), radius: size * 0.08, y: size * 0.04)
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)
            content
                .frame(width: size * 0.84, height: size * 0.84)
                .clipShape(Circle())
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.12), .clear, .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.84, height: size * 0.84)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
    }
}

/// A display key (D1–D4) screen.
struct KeyScreen: View {
    var image: NSImage?
    var label: String
    var size: CGFloat
    /// 0…1 while an image is being sent to this key.
    var uploading: Double? = nil
    /// D1–D4 have a factory picture; a blank DisplayPad key is just black.
    var factory = true

    /// Without a custom image the key shows its factory picture (label "D1"…"D4").
    private var shown: NSImage? {
        image ?? (factory ? Int(label.dropFirst()).flatMap { FactoryIcons.image($0 - 1) } : nil)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(Color(hex: 0x0E0F12))
                .shadow(color: Color(hex: FactoryIcons.blue).opacity(0.35), radius: size * 0.12)
            Group {
                if let shown {
                    Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Color(hex: factory ? FactoryIcons.blue : 0x000000)
                        .overlay(Text(label).font(.system(size: size * 0.24, weight: .heavy))
                            .foregroundStyle(factory ? .white : .white.opacity(0.25)))
                }
            }
            .frame(width: size * 0.8, height: size * 0.8)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
            if let p = uploading {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .frame(width: size * 0.8, height: size * 0.8)
                ProgressRing(value: p, lineWidth: max(2.5, size * 0.05))
                    .frame(width: size * 0.5, height: size * 0.5)
                Text("\(Int(p * 100))")
                    .font(.system(size: size * 0.15, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .strokeBorder(uploading != nil ? Theme.indigo : .white.opacity(0.14), lineWidth: uploading != nil ? 2 : 1)
        }
        .frame(width: size, height: size)
    }
}

struct ProgressRing: View {
    var value: Double
    var lineWidth: CGFloat = 4
    var tint: Color = Theme.indigo

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(LinearGradient(colors: [tint, Theme.pink], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: value)
        }
    }
}
