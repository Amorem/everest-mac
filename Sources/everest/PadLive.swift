import AppKit
import CoreGraphics
import Foundation

/// A live value drawn on a DisplayPad key instead of a picture, refreshed by
/// the daemon about once a second (the pad keeps pictures in RAM, so this
/// wears nothing).
enum LiveMetric: String, Codable, CaseIterable {
    case cpu, gpu, ram, disk, network, volume, clock
    /// Usage limits read from CodexBar (`CodexBarUsage`): the 5-hour
    /// window and the week, for Claude and for Codex.
    case claude, claudeWeek, codex, codexWeek

    /// Where a CodexBar metric comes from.
    private var codexBar: (provider: String, span: CodexBarUsage.Span)? {
        switch self {
        case .claude: return ("claude", .session)
        case .claudeWeek: return ("claude", .week)
        case .codex: return ("codex", .session)
        case .codexWeek: return ("codex", .week)
        default: return nil
        }
    }

    /// CodexBar metrics are offered only when its snapshot has that window
    /// (Codex plans without a 5-hour limit have none).
    var isAvailable: Bool {
        guard let c = codexBar else { return true }
        return CodexBarUsage.window(c.span, of: c.provider) != nil
    }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .disk: return tr("metric.disk")
        case .network: return tr("metric.network")
        case .volume: return tr("metric.volume")
        case .clock: return tr("mode.clock")
        case .claude: return "Claude 5h"
        case .claudeWeek: return "Claude \(tr("live.week"))"
        case .codex: return "Codex 5h"
        case .codexWeek: return "Codex \(tr("live.week"))"
        }
    }

    /// Same glyphs and colours as the dial's gauges (`MetricFace`).
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up.fill"
        case .ram: return "memorychip.fill"
        case .disk: return "internaldrive.fill"
        case .network: return "network"
        case .volume: return "speaker.wave.2.fill"
        case .clock: return "clock.fill"
        case .claude, .claudeWeek: return "sparkle"
        case .codex, .codexWeek: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var color: UInt32 {
        switch self {
        case .cpu: return 0x10B981
        case .gpu: return 0x8B5CF6
        case .ram: return 0xEC4899
        case .disk: return 0xF59E0B
        case .network: return 0x06B6D4
        case .volume: return 0x38BDF8
        case .clock: return 0xF3F4F7
        case .claude, .claudeWeek: return 0xD97757
        case .codex, .codexWeek: return 0x10A37F
        }
    }

    /// What pressing the key does if the user takes the suggestion.
    var suggestedAction: ButtonAction? {
        switch self {
        case .cpu, .gpu, .ram, .network:
            return ButtonAction(type: .app, value: "/System/Applications/Utilities/Activity Monitor.app")
        case .disk:
            return ButtonAction(type: .app, value: "/System/Applications/Utilities/Disk Utility.app")
        case .volume:
            return ButtonAction(type: .url, value: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
        case .clock:
            return ButtonAction(type: .app, value: "/System/Applications/Clock.app")
        case .claude, .claudeWeek:
            return ButtonAction(type: .url, value: "https://claude.ai/settings/usage")
        case .codex, .codexWeek:
            return ButtonAction(type: .url, value: "https://chatgpt.com/codex/settings/usage")
        }
    }

    /// "0 kB/s", "47 kB/s", "1.2 MB/s", "35 MB/s".
    static func rateText(_ bytesPerSecond: Double) -> String {
        let kB = bytesPerSecond / 1000
        if kB < 1000 { return "\(Int(kB.rounded())) kB/s" }
        let MB = kB / 1000
        return MB < 10 ? String(format: "%.1f MB/s", MB) : "\(Int(MB.rounded())) MB/s"
    }

    /// 0…1 for the gauge, and the text in its middle.
    func reading(_ s: MetricsSample, at date: Date) -> (fraction: Double, text: String) {
        func pct(_ v: UInt8) -> (Double, String) { (Double(min(v, 100)) / 100, "\(min(v, 100))%") }
        switch self {
        case .cpu: return pct(s.cpu)
        case .gpu: return pct(s.gpu)
        case .ram: return pct(s.ram)
        case .disk: return pct(s.disk)
        case .volume: return s.volumeLevel.map(pct) ?? (0, "—")
        case .network:
            // The gauge on a log scale from 1 kB/s to 100 MB/s.
            let kB = s.networkBytesPerSecond / 1000
            return (min(1, log10(1 + kB) / 5), LiveMetric.rateText(s.networkBytesPerSecond))
        case .clock:
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            let c = Calendar.current.dateComponents([.minute], from: date)
            return (Double(c.minute ?? 0) / 60, f.string(from: date))
        case .claude, .claudeWeek, .codex, .codexWeek:
            guard let c = codexBar, let w = CodexBarUsage.window(c.span, of: c.provider, now: date) else { return (0, "—") }
            return (w.usedPercent / 100, "\(Int(w.usedPercent.rounded()))%")
        }
    }
}

enum LiveTiles {
    /// One tile, `side` pixels square: the dial's ring gauge, glyph, value
    /// and label. Drawn with Core Graphics so the daemon can use it off the
    /// main thread.
    static func image(_ metric: LiveMetric, sample: MetricsSample, date: Date = Date(), side: Int = PadProto.keySide) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(side)
        let (fraction, text) = metric.reading(sample, at: date)
        let color = NSColor(rgb: metric.color)

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        // Ring: 80 % of a circle, open at the bottom, like the dial.
        let center = CGPoint(x: s / 2, y: s / 2)
        let radius = s * 0.40
        // Opening centred at the bottom (270°); y is up, so clockwise = decreasing angle.
        let start = CGFloat.pi * (1.5 - 0.2)
        let sweep = CGFloat.pi * 2 * 0.8
        ctx.setLineCap(.round)
        ctx.setLineWidth(s * 0.07)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        ctx.strokePath()
        if fraction > 0.005 {
            ctx.setShadow(offset: .zero, blur: s * 0.05, color: color.withAlphaComponent(0.7).cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep * CGFloat(fraction), clockwise: true)
            ctx.strokePath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Glyph, value, label: top to bottom inside the ring.
        if let glyph = glyph(metric, side: side) {
            let g = glyph.size
            glyph.draw(in: CGRect(x: (s - g.width) / 2, y: s * 0.62, width: g.width, height: g.height))
        }
        let valueSize = text.count > 5 ? s * 0.15 : s * 0.21
        draw(text, size: valueSize, weight: .bold, color: .white, centerY: s * 0.47, side: s, rounded: true)
        draw(metric.title.uppercased(), size: s * 0.085, weight: .bold, color: NSColor.white.withAlphaComponent(0.55),
             centerY: s * 0.29, side: s, rounded: false)
        return ctx.makeImage()
    }

    private static let glyphLock = NSLock()
    private static var glyphs: [String: NSImage] = [:]

    /// SF Symbols are looked up and configured once per metric and size.
    private static func glyph(_ metric: LiveMetric, side: Int) -> NSImage? {
        glyphLock.lock()
        defer { glyphLock.unlock() }
        let key = "\(metric.rawValue)-\(side)"
        if let g = glyphs[key] { return g }
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.13, weight: .semibold)
            .applying(.init(paletteColors: [NSColor(rgb: metric.color)]))
        let g = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyphs[key] = g
        return g
    }

    private static func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                             centerY: CGFloat, side: CGFloat, rounded: Bool) {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let b = str.size()
        let w = min(b.width, side * 0.7)
        str.draw(in: CGRect(x: (side - w) / 2, y: centerY - b.height / 2, width: w, height: b.height))
    }

    /// What the tile shows, to redraw it only when that changes.
    static func signature(_ metric: LiveMetric, sample: MetricsSample, date: Date = Date()) -> String {
        "live:\(metric.rawValue):\(metric.reading(sample, at: date).text)"
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
