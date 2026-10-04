import AppKit
import SwiftUI

/// The Everest Max drawn as hardware: brushed aluminium chassis, black caps
/// lit from below (the light bleeds between keys and shines through the
/// legends), the numpad module with its display keys, the media dock with
/// the round dial, and the side-strip underglow.
struct KeyboardCanvas<Dial: View>: View {
    enum Style { case hardware, compact }

    var main: [RGB]
    var side: [RGB]
    var style: Style = .hardware
    var displayImages: [NSImage?] = [nil, nil, nil, nil]
    var showLegends = true
    var paintable = false
    var onPaint: ((Int) -> Void)? = nil
    @ViewBuilder var dial: Dial

    var body: some View {
        GeometryReader { geo in
            let tf = Transform(size: geo.size, bounds: style == .hardware ? LedLayout.bounds : Self.compactBounds)
            Canvas { ctx, size in
                switch style {
                case .hardware: drawHardware(&ctx, tf)
                case .compact: drawCompact(&ctx, tf)
                }
            } symbols: {
                dial.frame(width: 240, height: 240).tag("dial")
            }
            .contentShape(Rectangle())
            .gesture(paintGesture(tf), including: paintable ? .all : .none)
        }
    }

    static var compactBounds: CGRect { LedLayout.keyField.insetBy(dx: -0.15, dy: -0.15) }

    private func paintGesture(_ tf: Transform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let u = tf.unit(g.location)
                if let key = LedLayout.keys.first(where: { $0.index != nil && hit($0, u) }), let idx = key.index {
                    onPaint?(idx)
                }
            }
    }

    private func hit(_ k: LedLayout.Key, _ p: CGPoint) -> Bool {
        CGRect(x: k.x, y: k.y, width: k.w, height: k.h).contains(p)
    }

    // MARK: - Transform

    struct Transform {
        let scale: CGFloat
        let ox: CGFloat
        let oy: CGFloat
        let bounds: CGRect

        init(size: CGSize, bounds: CGRect) {
            self.bounds = bounds
            scale = min(size.width / bounds.width, size.height / bounds.height)
            ox = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
            oy = (size.height - bounds.height * scale) / 2 - bounds.minY * scale
        }

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        func r(_ r: CGRect) -> CGRect {
            CGRect(x: ox + r.minX * scale, y: oy + r.minY * scale, width: r.width * scale, height: r.height * scale)
        }
        func unit(_ pt: CGPoint) -> CGPoint { CGPoint(x: (pt.x - ox) / scale, y: (pt.y - oy) / scale) }
    }

    // MARK: - Hardware

    private func colour(of key: LedLayout.Key) -> RGB? {
        guard let i = key.index, i < main.count else { return nil }
        return main[i]
    }

    private func drawHardware(_ ctx: inout GraphicsContext, _ tf: Transform) {
        let s = tf.scale

        // 1. Underglow from the side strips, spilling onto the desk.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: s * 0.7))
            for (led, pt) in LedLayout.sidePoints.enumerated() where led < side.count {
                let c = side[led]
                guard c.luminance > 0.02 else { continue }
                let center = tf.p(pt.x, pt.y)
                let rad = s * 0.75
                layer.fill(Path(ellipseIn: CGRect(x: center.x - rad, y: center.y - rad * 0.8,
                                                  width: rad * 2, height: rad * 1.6)),
                           with: .color(Color(rgb: c).opacity(0.6)))
            }
        }

        // 2. Chassis.
        for rect in [LedLayout.mainChassis, LedLayout.numpadChassis] {
            drawChassis(&ctx, tf.r(rect), s)
        }

        // 3. Backlight bleeding between the caps.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: s * 0.13))
            for key in LedLayout.keys where key.zone != .display {
                guard let c = colour(of: key), c.luminance > 0.01 else { continue }
                let path = capPath(key, tf, inset: -0.02, radius: 0.16)
                layer.fill(path, with: .color(Color(rgb: c).opacity(0.95)))
            }
        }

        // 4. Caps + legends.
        for key in LedLayout.keys {
            if key.zone == .display {
                drawDisplayKey(&ctx, key, tf)
            } else if key.special {
                drawEscKey(&ctx, key, tf, colour(of: key))
            } else {
                drawCap(&ctx, key, tf, colour(of: key))
            }
        }

        // 5. Media dock + dial on top.
        drawDock(&ctx, tf)
    }

    private func drawChassis(_ ctx: inout GraphicsContext, _ rect: CGRect, _ s: CGFloat) {
        let path = Path(roundedRect: rect, cornerRadius: s * 0.32, style: .continuous)
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [Color(hex: 0x30333B), Color(hex: 0x23252B), Color(hex: 0x1A1B20)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        // Brushed finish: faint horizontal hairlines.
        var lines = ctx
        lines.clip(to: path)
        let step = max(2, s * 0.07)
        var y = rect.minY
        var n = 0
        while y < rect.maxY {
            let alpha = 0.012 + 0.018 * Noise.hash(n * 7 + Int(rect.minX))
            lines.fill(Path(CGRect(x: rect.minX, y: y, width: rect.width, height: 0.7)),
                       with: .color(.white.opacity(alpha)))
            y += step
            n += 1
        }
        // Bevel: bright top edge, dark outline.
        ctx.stroke(path, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.28), .white.opacity(0.05), .black.opacity(0.4)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)),
            lineWidth: max(1, s * 0.035))
    }

    private func capPath(_ key: LedLayout.Key, _ tf: Transform, inset: CGFloat, radius: CGFloat) -> Path {
        let s = tf.scale
        let gap: CGFloat = 0.07 + inset
        switch key.shape {
        case .rect:
            let r = tf.r(CGRect(x: key.x + gap, y: key.y + gap, width: key.w - 2 * gap, height: key.h - 2 * gap))
            return Path(roundedRect: r, cornerRadius: s * radius, style: .continuous)
        case .isoEnter:
            // 1.5u on the top row, 1.25u on the home row (notch on the left).
            let x0 = key.x + gap, x1 = key.x + key.w - gap
            let xn = key.x + 0.25 + gap
            let y0 = key.y + gap, ym = key.y + 1 + gap, y1 = key.y + key.h - gap
            var p = Path()
            let pts = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1),
                       CGPoint(x: xn, y: y1), CGPoint(x: xn, y: ym), CGPoint(x: x0, y: ym)]
            let rr = radius
            p.move(to: tf.p((pts[0].x + pts[1].x) / 2, pts[0].y))
            for i in 1...6 {
                let a = pts[i % 6], b = pts[(i + 1) % 6]
                p.addArc(tangent1End: tf.p(a.x, a.y), tangent2End: tf.p(b.x, b.y), radius: s * rr)
            }
            p.closeSubpath()
            return p
        }
    }

    private func drawCap(_ ctx: inout GraphicsContext, _ key: LedLayout.Key, _ tf: Transform, _ led: RGB?) {
        let s = tf.scale
        let skirt = capPath(key, tf, inset: 0, radius: 0.13)
        ctx.fill(skirt, with: .color(Color(hex: 0x0C0D10)))

        // Top face, offset up like a sculpted cap.
        var top = capPath(key, tf, inset: 0.085, radius: 0.1)
        top = top.applying(CGAffineTransform(translationX: 0, y: -s * 0.035))
        let b = top.boundingRect
        ctx.fill(top, with: .linearGradient(
            Gradient(colors: [Color(hex: 0x26282E), Color(hex: 0x18191D)]),
            startPoint: CGPoint(x: b.midX, y: b.minY), endPoint: CGPoint(x: b.midX, y: b.maxY)))
        ctx.stroke(top, with: .color(.white.opacity(0.07)), lineWidth: max(0.5, s * 0.015))

        guard showLegends, s > 16 else { return }
        let lit = (led?.luminance ?? 0) > 0.02
        let ink: Color = lit ? Color(rgb: RGB.mix(led!, .white, 0.28)) : Color(hex: 0x3C3F48)
        let labelCenter = key.shape == .isoEnter
            ? tf.p(key.x + key.w / 2 + 0.1, key.y + 0.5 - 0.035)
            : CGPoint(x: b.midX, y: b.midY)
        let isWord = key.label.count > 2
        // Long words (DRUCK S-ABF, Barre d'espace…) shrink to stay on the cap.
        let fit = key.label.count > 5 ? 5.0 / Double(key.label.count) * (key.w > 1.6 ? 1.8 : 1.0) : 1.0
        let size = (isWord ? min(s * 0.15, 11) : min(s * 0.27, 17)) * CGFloat(min(1.0, fit))
        let font = Font.system(size: size, weight: isWord ? .bold : .semibold)
        if let topLegend = key.top {
            let small = Font.system(size: min(s * (topLegend.count > 1 ? 0.13 : 0.22), 13), weight: .semibold)
            ctx.draw(ctx.resolve(Text(topLegend).font(small).foregroundColor(ink)),
                     at: CGPoint(x: labelCenter.x, y: labelCenter.y - s * 0.17))
            ctx.draw(ctx.resolve(Text(key.label).font(font).foregroundColor(ink)),
                     at: CGPoint(x: labelCenter.x, y: labelCenter.y + s * 0.13))
        } else if !key.label.isEmpty {
            ctx.draw(ctx.resolve(Text(key.label).font(font).foregroundColor(ink)), at: labelCenter)
        }
    }

    private func drawEscKey(_ ctx: inout GraphicsContext, _ key: LedLayout.Key, _ tf: Transform, _ led: RGB?) {
        let s = tf.scale
        let skirt = capPath(key, tf, inset: 0, radius: 0.13)
        ctx.fill(skirt, with: .color(Color(hex: 0x6A6E78)))
        var top = capPath(key, tf, inset: 0.085, radius: 0.1)
        top = top.applying(CGAffineTransform(translationX: 0, y: -s * 0.035))
        let b = top.boundingRect
        ctx.fill(top, with: .linearGradient(
            Gradient(colors: [Color(hex: 0xD9DCE2), Color(hex: 0x9EA3AD)]),
            startPoint: CGPoint(x: b.minX, y: b.minY), endPoint: CGPoint(x: b.maxX, y: b.maxY)))
        // The Mountain mark, tinted by the key's LED (grey when unlit).
        let lit = (led?.luminance ?? 0) > 0.02
        let tint: Color = lit ? Color(rgb: led!).opacity(0.95) : Color(hex: 0x5A5E66)
        let w = b.width * 0.64, h = w / MountainMark.aspect
        let rect = CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
        ctx.drawLayer { layer in
            layer.draw(Image(nsImage: MountainMark.image), in: rect)
            layer.blendMode = .sourceIn
            layer.fill(Path(rect), with: .color(tint))
        }
    }

    private func drawDisplayKey(_ ctx: inout GraphicsContext, _ key: LedLayout.Key, _ tf: Transform) {
        let s = tf.scale
        let i = Int(key.label.dropFirst()).map { $0 - 1 } ?? 0
        let outer = tf.r(CGRect(x: key.x + 0.1, y: key.y + 0.06, width: key.w - 0.2, height: key.h - 0.12))
        let glow = Color(hex: 0x7CC8FF)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: s * 0.12))
            l.fill(Path(roundedRect: outer, cornerRadius: s * 0.12), with: .color(glow.opacity(0.55)))
        }
        ctx.fill(Path(roundedRect: outer, cornerRadius: s * 0.12, style: .continuous), with: .color(Color(hex: 0x0E0F12)))
        let screen = outer.insetBy(dx: s * 0.09, dy: s * 0.09)
        let screenPath = Path(roundedRect: screen, cornerRadius: s * 0.06, style: .continuous)
        if i < displayImages.count, let img = displayImages[i] {
            var c = ctx
            c.clip(to: screenPath)
            c.draw(Image(nsImage: img).resizable(), in: screen)
        } else {
            ctx.fill(screenPath, with: .linearGradient(
                Gradient(colors: [Color(hex: 0xBFE6FF), Color(hex: 0x4FA9FF)]),
                startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
            if s > 16 {
                ctx.draw(ctx.resolve(Text(key.label).font(.system(size: min(s * 0.2, 12), weight: .heavy))
                    .foregroundColor(.white.opacity(0.9))), at: CGPoint(x: screen.midX, y: screen.midY))
            }
        }
        ctx.stroke(Path(roundedRect: outer, cornerRadius: s * 0.12, style: .continuous),
                   with: .color(.white.opacity(0.12)), lineWidth: 1)
    }

    private func drawDock(_ ctx: inout GraphicsContext, _ tf: Transform) {
        let s = tf.scale
        let dock = tf.r(LedLayout.dock)
        let shape = Path(roundedRect: dock, cornerRadius: dock.height / 2, style: .continuous)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: s * 0.15))
            l.fill(shape.applying(CGAffineTransform(translationX: 0, y: s * 0.1)), with: .color(.black.opacity(0.6)))
        }
        ctx.fill(shape, with: .linearGradient(
            Gradient(colors: [Color(hex: 0x24262C), Color(hex: 0x131418)]),
            startPoint: CGPoint(x: dock.midX, y: dock.minY), endPoint: CGPoint(x: dock.midX, y: dock.maxY)))
        ctx.stroke(shape, with: .color(.white.opacity(0.12)), lineWidth: max(1, s * 0.025))

        // Profile indicator dots.
        for k in 0..<4 {
            let c = tf.p(LedLayout.dock.minX + 0.42, LedLayout.dock.minY + 0.38 + CGFloat(k) * 0.2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - s * 0.035, y: c.y - s * 0.035, width: s * 0.07, height: s * 0.07)),
                     with: .color(.white.opacity(k == 0 ? 0.75 : 0.22)))
        }

        // Five media buttons.
        let glyphs = ["backward.end.fill", "forward.end.fill", "playpause.fill", "speaker.slash.fill", "sun.max.fill"]
        for (k, g) in glyphs.enumerated() {
            let cx = LedLayout.dock.minX + 1.15 + CGFloat(k) * 1.05
            let c = tf.p(cx, LedLayout.dock.minY + 0.56)
            let r = s * 0.31
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x3A3D45), Color(hex: 0x1C1D22)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.14)), lineWidth: 0.8)
            if s > 18 {
                let icon = ctx.resolve(Image(systemName: g))
                let gy = tf.p(cx, LedLayout.dock.minY + 1.08)
                let side = s * 0.16
                var gc = ctx
                gc.opacity = 0.45
                gc.draw(icon, in: CGRect(x: gy.x - side, y: gy.y - side / 2, width: side * 2, height: side))
            }
        }

        // The dial: brushed ring, round screen.
        let dc = tf.p(LedLayout.dialCenter.x, LedLayout.dialCenter.y)
        let R = LedLayout.dialRadius * s
        let ring = CGRect(x: dc.x - R, y: dc.y - R, width: R * 2, height: R * 2)
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: s * 0.18))
            l.fill(Path(ellipseIn: ring.offsetBy(dx: 0, dy: s * 0.12)), with: .color(.black.opacity(0.7)))
        }
        ctx.fill(Path(ellipseIn: ring), with: .linearGradient(
            Gradient(colors: [Color(hex: 0x4A4E57), Color(hex: 0x1E2025), Color(hex: 0x3A3D45)]),
            startPoint: CGPoint(x: ring.minX, y: ring.minY), endPoint: CGPoint(x: ring.maxX, y: ring.maxY)))
        ctx.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.22)), lineWidth: max(1, s * 0.03))
        let screen = ring.insetBy(dx: R * 0.14, dy: R * 0.14)
        ctx.fill(Path(ellipseIn: screen), with: .color(.black))
        if let sym = ctx.resolveSymbol(id: "dial") {
            var c = ctx
            c.clip(to: Path(ellipseIn: screen))
            c.draw(sym, in: screen)
        }
        ctx.fill(Path(ellipseIn: screen), with: .linearGradient(
            Gradient(colors: [.white.opacity(0.12), .clear, .clear]),
            startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
    }

    // MARK: - Compact (effect tiles)

    private func drawCompact(_ ctx: inout GraphicsContext, _ tf: Transform) {
        let s = tf.scale
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: s * 0.25))
            for key in LedLayout.keys where key.index != nil {
                guard let c = colour(of: key), c.luminance > 0.01 else { continue }
                layer.fill(capPath(key, tf, inset: 0, radius: 0.2), with: .color(Color(rgb: c).opacity(0.7)))
            }
        }
        for key in LedLayout.keys where key.index != nil {
            let c = colour(of: key) ?? .black
            let path = capPath(key, tf, inset: 0.02, radius: 0.18)
            let lit = c.luminance > 0.01
            ctx.fill(path, with: .color(lit ? Color(rgb: c) : Color.white.opacity(0.05)))
        }
    }
}

extension KeyboardCanvas where Dial == Color {
    init(main: [RGB], side: [RGB], style: Style = .hardware) {
        self.main = main
        self.side = side
        self.style = style
        self.dial = Color.black
    }
}

/// Animated preview of a Mac effect on the real layout.
struct EffectPreview: View {
    var effect: LedEffect
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let f = LedRenderer.render(effect, time: context.date.timeIntervalSinceReferenceDate)
            KeyboardCanvas(main: f.main, side: f.side, style: .compact)
        }
    }
}

/// Animated preview of a firmware effect (simulated).
struct FirmwarePreview: View {
    var lighting: FirmwareLighting
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let f = LedRenderer.render(lighting, time: context.date.timeIntervalSinceReferenceDate)
            KeyboardCanvas(main: f.main, side: f.side, style: .compact)
        }
    }
}

/// Average of the lit colours — tints the ambient glow behind the board.
func dominantColor(_ main: [RGB], _ side: [RGB]) -> Color {
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for c in main where Int(c.r) + Int(c.g) + Int(c.b) > 60 {
        r += Double(c.r); g += Double(c.g); b += Double(c.b); n += 1
    }
    guard n > 0 else { return Theme.accent }
    return Color(red: r / n / 255, green: g / n / 255, blue: b / n / 255)
}
