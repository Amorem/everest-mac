import AppKit
import SwiftUI

/// Everest's own mark, drawn in code: a keycap with a ridge inside. One source
/// for the app icon (`everest app-icon`), the sidebar, the menu bar and the
/// picture shown for D1.
enum BrandMark {
    /// The white mark on a transparent background, square.
    static let image: NSImage = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
        draw(in: rect, color: .white)
        return true
    }

    static var aspect: CGFloat { 1 }

    static func draw(in rect: NSRect, color: NSColor) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        color.setStroke()
        color.setFill()
        let inset = rect.width * 0.07
        let cap = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                               xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
        cap.lineWidth = rect.width * 0.085
        cap.stroke()

        let ridge = NSBezierPath()
        ridge.move(to: point(0.20, 0.26))
        ridge.line(to: point(0.44, 0.73))
        ridge.line(to: point(0.565, 0.485))
        ridge.line(to: point(0.645, 0.60))
        ridge.line(to: point(0.80, 0.26))
        ridge.close()
        ridge.lineJoinStyle = .round
        ridge.lineWidth = rect.width * 0.025
        ridge.fill()
        ridge.stroke()
    }

    /// Menu-bar icon: a template image (macOS tints it for light, dark and
    /// the highlighted state). `dot` adds a dot, as a cut-out ring so it reads
    /// in one colour too: a missing permission, or an update waiting.
    static func menuBarImage(dot: Bool) -> NSImage {
        let size = NSSize(width: dot ? 24 : 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            draw(in: NSRect(x: 0.5, y: 0.5, width: 17, height: 17), color: .black)
            if dot, let ctx = NSGraphicsContext.current?.cgContext {
                let c = CGPoint(x: rect.maxX - 4.2, y: 13.2)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: c.x - 4.6, y: c.y - 4.6, width: 9.2, height: 9.2))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - 3.2, y: c.y - 3.2, width: 6.4, height: 6.4))
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// The app icon: a macOS rounded square with the white mark.
    private static func appIcon(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let side = CGFloat(pixels)
        let tile = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.098, dy: side * 0.098)
        let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        NSGradient(starting: NSColor(hex: tileTop), ending: NSColor(hex: tileBottom))?.draw(in: shape, angle: -90)
        draw(in: tile.insetBy(dx: tile.width * 0.17, dy: tile.width * 0.17), color: .white)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// `everest app-icon out.iconset`, then `iconutil -c icns` gives
    /// assets/AppIcon.icns.
    static func writeIconset(to path: String) throws {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try appIcon(pixels: points * scale)?.write(to: dir.appendingPathComponent(name))
            }
        }
    }

    static let tileTop: UInt32 = 0x2B3A5C
    static let tileBottom: UInt32 = 0x0F1626
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The mark on its tile, for the sidebar.
struct BrandTile: View {
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: BrandMark.tileTop), Color(hex: BrandMark.tileBottom)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
            Image(nsImage: BrandMark.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.68)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: BrandMark.tileTop).opacity(0.55), radius: size * 0.22, y: size * 0.06)
    }
}
