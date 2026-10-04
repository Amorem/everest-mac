// Builds the app icon: macOS rounded square in Mountain blue with the white
// logo. Usage: swift tools/make-icon.swift <logo.png> <out.iconset> [mark.png]
// The optional third argument also writes the bare white mark (512 px wide)
// that the app embeds for its sidebar and menu-bar icon.
// <logo.png> is the wide Mountain logo (mark on the left); the mark is cropped.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let src = NSImage(contentsOfFile: args[1]),
      var logo = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make-icon.swift <logo.png> <out.iconset>"); exit(1)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// Keep the mark only (the wide file also holds the lettering on the right):
// find the first big empty gap, scanning the alpha channel by column.
let w = logo.width, h = logo.height
let bpr = w * 4
var px = [UInt8](repeating: 0, count: bpr * h)
let cs = CGColorSpaceCreateDeviceRGB()
px.withUnsafeMutableBytes { p in
    let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(logo, in: CGRect(x: 0, y: 0, width: w, height: h))
}
// Keep only the mark: flood-fill (8-connected) from the left-most opaque
// pixel. The lettering is a separate group of shapes, and its first letter
// sits right under the mark's tip, so cropping by columns would not do.
var start = -1
search: for x in 0..<w { for y in 0..<h where px[y * bpr + x * 4 + 3] > 40 { start = y * w + x; break search } }
var inMark = [Bool](repeating: false, count: w * h)
var stack = [start]
inMark[start] = true
while let i = stack.popLast() {
    let x = i % w, y = i / w
    for dy in -1...1 { for dx in -1...1 {
        let nx = x + dx, ny = y + dy
        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
        let j = ny * w + nx
        if !inMark[j] && px[j * 4 + 3] > 8 { inMark[j] = true; stack.append(j) }
    } }
}
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w where inMark[y * w + x] {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
// Erase everything that is not the mark, then crop. Inside the mark the
// logo draws its inner stroke in opaque white: that becomes a cut-out, so
// the white mark keeps its blue detail like the picture on D1.
for i in 0..<(w * h) {
    let isWhite = px[i * 4] > 180 && px[i * 4 + 1] > 180 && px[i * 4 + 2] > 180
    if !inMark[i] || isWhite { px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0 }
}
let cleaned: CGImage = px.withUnsafeMutableBytes { p in
    CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
logo = cleaned.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

// The mark in white, same alpha.
let lw = logo.width, lh = logo.height
let white = CGContext(data: nil, width: lw, height: lh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
white.draw(logo, in: CGRect(x: 0, y: 0, width: lw, height: lh))
white.setBlendMode(.sourceIn)
white.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
white.fill(CGRect(x: 0, y: 0, width: lw, height: lh))
let mark = white.makeImage()!

if args.count >= 4 {
    let mw = 512, mh = Int((Double(mark.height) * 512 / Double(mark.width)).rounded())
    let c = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(mark, in: CGRect(x: 0, y: 0, width: mw, height: mh))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // macOS icon grid: the body is 824/1024 of the canvas.
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 28 / 1024,
                  color: CGColor(red: 0, green: 0, blue: 0.1, alpha: 0.4))
    ctx.addPath(path); ctx.setFillColor(CGColor(red: 0, green: 0.267, blue: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.16, green: 0.40, blue: 1.0, alpha: 1),   // lighter at the top
        CGColor(red: 0.0, green: 0.22, blue: 0.90, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.minY), options: [])

    // The logo, centred, about 62 % of the body.
    let gw = body.width * 0.66
    let gh = gw * CGFloat(lh) / CGFloat(lw)
    ctx.draw(mark, in: CGRect(x: body.midX - gw / 2, y: body.midY - gh / 2, width: gw, height: gh))
    ctx.restoreGState()

    // Thin inner edge for definition.
    ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(max(1, s * 2 / 1024)); ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out.path)")
