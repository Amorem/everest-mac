import AppKit
import SwiftUI

/// Design tokens. One dark theme — RGB hardware reads best on near-black —
/// with a colour per section, like System Settings' icon badges.
enum Theme {
    static let canvas = Color(hex: 0x0B0C11)
    static let surface = Color(hex: 0x14161E)
    static let surfaceRaised = Color(hex: 0x1B1E28)
    static let surfaceSunken = Color(hex: 0x0F1016)
    static let hover = Color.white.opacity(0.05)
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.13)

    static let text = Color(hex: 0xF3F4F7)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.36)

    static let violet = Color(hex: 0x8B5CF6)
    static let pink = Color(hex: 0xEC4899)
    static let rose = Color(hex: 0xF43F5E)
    static let orange = Color(hex: 0xF97316)
    static let amber = Color(hex: 0xF59E0B)
    static let emerald = Color(hex: 0x10B981)
    static let cyan = Color(hex: 0x06B6D4)
    static let sky = Color(hex: 0x38BDF8)
    static let indigo = Color(hex: 0x6366F1)
    static let success = Color(hex: 0x34D399)
    static let danger = Color(hex: 0xF87171)

    static let accent = violet

    /// The brand gradient: violet → pink, used for primary actions.
    static let accentGradient = LinearGradient(colors: [violet, pink], startPoint: .leading, endPoint: .trailing)

    /// A full spectrum — the "RGB" signature, used sparingly.
    static let spectrum = LinearGradient(
        colors: [Color(hex: 0xFF3B6B), Color(hex: 0xFF9F1C), Color(hex: 0xFFE14D),
                 Color(hex: 0x3DFFB0), Color(hex: 0x3DB8FF), Color(hex: 0xA25BFF)],
        startPoint: .leading, endPoint: .trailing)

    static func gradient(_ c: Color) -> LinearGradient {
        LinearGradient(colors: [c.opacity(0.95), c.lighter(0.18)], startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 9
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }

    init(rgb: RGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    func lighter(_ amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return Color(red: min(1, ns.redComponent + amount), green: min(1, ns.greenComponent + amount),
                     blue: min(1, ns.blueComponent + amount))
    }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - Surfaces

struct Card<Content: View, Trailing: View>: View {
    var title: String?
    var subtitle: String?
    var icon: String?
    var tint: Color
    var padding: CGFloat
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, icon: String? = nil, tint: Color = Theme.accent,
         padding: CGFloat = 18,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.padding = padding
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || icon != nil {
                HStack(alignment: .center, spacing: 11) {
                    if let icon { IconBadge(icon: icon, tint: tint, size: 28) }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text)
                        }
                        if let subtitle {
                            Text(subtitle).font(.ui(11.5)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SurfaceBackground())
    }
}

struct SurfaceBackground: View {
    var radius: CGFloat = Theme.radius
    var fill: Color = Theme.surface
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.025), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

/// Rounded-square symbol badge, System Settings style.
struct IconBadge: View {
    var icon: String
    var tint: Color
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.gradient(tint))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
            Image(systemName: icon)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
    }
}

struct Caption: View {
    var text: String
    var icon: String? = nil
    init(_ text: String, icon: String? = nil) { self.text = text; self.icon = icon }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon { Image(systemName: icon).font(.ui(10.5, .semibold)) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.ui(11.5))
        .foregroundStyle(Theme.textTertiary)
    }
}

struct FieldLabel: View {
    var text: String
    var value: String? = nil
    init(_ text: String, value: String? = nil) { self.text = text; self.value = value }
    var body: some View {
        HStack {
            Text(text).font(.ui(11.5, .medium)).foregroundStyle(Theme.textSecondary)
            Spacer()
            if let value {
                Text(value).font(.ui(11.5, .semibold).monospacedDigit()).foregroundStyle(Theme.text)
            }
        }
    }
}

// MARK: - Buttons

struct ActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var tint: Color? = nil
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButtonBody(configuration: configuration, kind: kind, tint: tint, compact: compact)
    }

    private struct StyledButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let tint: Color?
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.ui(compact ? 11.5 : 12.5, .semibold))
                .labelStyle(TightLabelStyle())
                .padding(.horizontal, compact ? 10 : 14)
                .frame(height: compact ? 26 : 32)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .foregroundStyle(foreground)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }

        @ViewBuilder private var background: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            switch kind {
            case .primary:
                if let tint {
                    shape.fill(Theme.gradient(tint)).brightness(hovering ? 0.06 : 0)
                } else {
                    shape.fill(Theme.accentGradient).brightness(hovering ? 0.06 : 0)
                }
            case .secondary:
                shape.fill(hovering ? Color.white.opacity(0.10) : Color.white.opacity(0.06))
            case .ghost:
                shape.fill(hovering ? Color.white.opacity(0.06) : Color.clear)
            case .danger:
                shape.fill(Theme.danger.opacity(hovering ? 0.22 : 0.14))
            }
        }

        private var border: Color {
            switch kind {
            case .primary: return .white.opacity(0.14)
            case .secondary: return Theme.stroke
            case .ghost: return .clear
            case .danger: return Theme.danger.opacity(0.3)
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .danger: return Theme.danger
            default: return Theme.text
            }
        }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.ui(11, .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static var primary: ActionButtonStyle { ActionButtonStyle(kind: .primary) }
    static var secondary: ActionButtonStyle { ActionButtonStyle(kind: .secondary) }
    static var ghost: ActionButtonStyle { ActionButtonStyle(kind: .ghost) }
    static var danger: ActionButtonStyle { ActionButtonStyle(kind: .danger) }
    static func primary(_ tint: Color) -> ActionButtonStyle { ActionButtonStyle(kind: .primary, tint: tint) }
    static func compact(_ kind: ActionButtonStyle.Kind = .secondary) -> ActionButtonStyle {
        ActionButtonStyle(kind: kind, compact: true)
    }
}

/// Small round icon-only button.
struct IconButton: View {
    var icon: String
    var help: String
    var tint: Color = Theme.text
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.ui(12, .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06)))
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Segmented control

struct Segmented<T: Hashable>: View {
    struct Item {
        let value: T
        let title: String
        var icon: String? = nil
        var help: String? = nil
    }

    let items: [Item]
    @Binding var selection: T
    var tint: Color = Theme.accent
    var fill = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let icon = item.icon { Image(systemName: icon).font(.ui(10.5, .semibold)) }
                        if !item.title.isEmpty { Text(item.title).lineLimit(1) }
                    }
                    .font(.ui(11.5, .semibold))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .frame(height: 26)
                    .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.gradient(tint))
                                .shadow(color: tint.opacity(0.35), radius: 6, y: 2)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help ?? item.title)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// A wrapping grid of selectable chips — for option sets too long for a
/// segmented control.
struct ChipGrid<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var tint: Color = Theme.accent
    var columns = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.0 == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = item.0 }
                } label: {
                    Text(item.1)
                        .font(.ui(11.5, .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? AnyShapeStyle(Theme.gradient(tint)) : AnyShapeStyle(Theme.surfaceSunken)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.white.opacity(0.15) : Theme.stroke, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Slider

/// Slider with a gradient fill, optional discrete steps and tick labels.
struct GlowSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double? = nil
    var tint: Color = Theme.accent
    var gradient: LinearGradient? = nil
    var ticks: [String] = []
    var onCommit: (() -> Void)? = nil
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let knobX = 8 + (w - 16) * f
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                        .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                        .frame(height: 6)
                    if let step, step > 0 {
                        let n = Int(((range.upperBound - range.lowerBound) / step).rounded())
                        if n <= 10 {
                            ForEach(0...n, id: \.self) { i in
                                Circle().fill(Color.white.opacity(0.18))
                                    .frame(width: 3, height: 3)
                                    .position(x: 8 + (w - 16) * CGFloat(i) / CGFloat(n), y: 9)
                            }
                        }
                    }
                    Capsule()
                        .fill(gradient ?? LinearGradient(colors: [tint.opacity(0.7), tint.lighter(0.12)],
                                                         startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, knobX), height: 6)
                        .shadow(color: tint.opacity(0.45), radius: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: dragging ? 17 : 15, height: dragging ? 17 : 15)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .position(x: knobX, y: 9)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let raw = Double((g.location.x - 8) / max(1, w - 16))
                            var v = range.lowerBound + max(0, min(1, raw)) * (range.upperBound - range.lowerBound)
                            if let step, step > 0 { v = (v / step).rounded() * step }
                            v = max(range.lowerBound, min(range.upperBound, v))
                            if v != value { value = v }
                        }
                        .onEnded { _ in
                            dragging = false
                            onCommit?()
                        }
                )
                .animation(.easeOut(duration: 0.1), value: dragging)
            }
            .frame(height: 18)
            if !ticks.isEmpty {
                HStack {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                        Text(t).font(.ui(10, .medium)).foregroundStyle(Theme.textTertiary)
                        if i < ticks.count - 1 { Spacer() }
                    }
                }
            }
        }
    }
}

// MARK: - Colour well

struct ColorDot: View {
    var color: RGB
    var size: CGFloat = 34
    var selected = false
    var label: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Color(rgb: color))
                        .shadow(color: Color(rgb: color).opacity(0.55), radius: hovering ? 9 : 6)
                    Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    if selected {
                        Circle().strokeBorder(.white, lineWidth: 2).padding(-4)
                    }
                }
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.06 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("#\(color.hex.uppercased())")
            if let label {
                Text(label).font(.ui(10.5, .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - Status

struct StatusDot: View {
    var on: Bool
    var color: Color = Theme.success
    var body: some View {
        Circle()
            .fill(on ? color : Color.white.opacity(0.25))
            .frame(width: 7, height: 7)
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: 4)
    }
}

struct Pill: View {
    var text: String
    var icon: String? = nil
    var tint: Color = Theme.textSecondary
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.ui(9.5, .bold)) }
            Text(text).font(.ui(11, .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Text field

struct StyledField: View {
    var placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.ui(11, .semibold)).foregroundStyle(Theme.textTertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .ui(12.5))
                .foregroundStyle(Theme.text)
                .focused($focused)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceSunken))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.stroke, lineWidth: focused ? 1.5 : 1)
        )
    }
}

// MARK: - Window chrome

/// NSVisualEffectView bridge for the translucent sidebar.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
