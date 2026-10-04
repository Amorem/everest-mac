import CoreGraphics
import Foundation
import ImageIO

enum ImageError: Error, CustomStringConvertible, LocalizedError {
    case cannotOpen(String)
    case cannotDecode(String)
    case frameOutOfRange(Int, Int)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .cannotOpen(let p): return "cannot open image: \(p)"
        case .cannotDecode(let p): return "cannot decode image: \(p)"
        case .frameOutOfRange(let f, let n): return "frame \(f) out of range (image has \(n) frames)"
        }
    }
}

enum ImageTools {
    /// Convert an image file (PNG/JPEG/GIF, any size) to RGB565 little-endian
    /// bytes at the target size — the format both displays expect.
    static func rgb565(path: String, width: Int, height: Int, frame: Int = 0) throws -> [UInt8] {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageError.cannotOpen(path)
        }
        let count = CGImageSourceGetCount(src)
        guard frame >= 0 && frame < max(count, 1) else {
            throw ImageError.frameOutOfRange(frame, count)
        }
        guard let image = CGImageSourceCreateImageAtIndex(src, frame, nil) else {
            throw ImageError.cannotDecode(path)
        }
        return try rgb565(image: image, width: width, height: height)
    }

    static func rgb565(image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ImageError.cannotDecode("bitmap context") }

        var out = [UInt8](repeating: 0, count: width * height * 2)
        var o = 0
        var i = 0
        while i < rgba.count {
            let r = UInt16(rgba[i])
            let g = UInt16(rgba[i + 1])
            let b = UInt16(rgba[i + 2])
            let hi = UInt8((r & 0xF8) | (g >> 5))
            let lo = UInt8(((g << 3) & 0xE0) | (b >> 3))
            out[o] = lo
            out[o + 1] = hi
            o += 2
            i += 4
        }
        return out
    }

    static var imageExtensions: Set<String> { ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"] }
}
