import AppKit

/// What the app shows for a display key without a custom picture: the same
/// meaning as the keyboard's own factory pictures, on the same flat blue. The
/// keyboard keeps its pictures in its flash and restores them on "reset"; none
/// of them is embedded here, and these are never sent to the keyboard.
enum FactoryIcons {
    private static let symbols: [String?] = [nil, "folder.fill", "moon.fill", "waveform.path.ecg"]
    private static let cache: [NSImage] = symbols.map(render)

    /// Picture of a display key (0 = D1 … 3 = D4).
    static func image(_ key: Int) -> NSImage? {
        (0..<4).contains(key) ? cache[key] : nil
    }

    /// The flat background of these pictures.
    static let blue: UInt32 = 0x0044FF

    private static func render(_ symbol: String?) -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor(srgbRed: 0, green: 0x44 / 255, blue: 1, alpha: 1).setFill()
            rect.fill()
            guard let symbol else {
                BrandMark.draw(in: rect.insetBy(dx: 56, dy: 56), color: .white)
                return true
            }
            let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return true }
            let size = glyph.size
            glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
            return true
        }
    }
}
