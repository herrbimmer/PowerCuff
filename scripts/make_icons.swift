// Usage: swift scripts/make_icons.swift "<source.jpg>" <outDir>
// Produces <outDir>/AppIcon.iconset (for iconutil) and <outDir>/MenuBarIcon.png (template glyph).
import AppKit
import CoreImage

let args = CommandLine.arguments
let src = args[1], out = args[2]
guard let nsImg = NSImage(contentsOfFile: src),
      let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("cannot read \(src)") }
let H = cg.height
// Artwork is centred at ~x=1224 of a 2400x1792 frame; take the full-height square around it.
let cx = min(max(1224, H / 2), cg.width - H / 2)
let square = cg.cropping(to: CGRect(x: cx - H / 2, y: 0, width: H, height: H))!

func png(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(size))
    return ctx.makeImage()!
}

// App icon: macOS-style rounded tile (824/1024 content area) with soft shadow.
func appIcon(_ px: Int) -> CGImage {
    render(size: px) { ctx, s in
        let inset = s * 100 / 1024
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.5))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.04, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.draw(square, in: tile)
        ctx.restoreGState()
    }
}

let iconset = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    png(appIcon(base), to: "\(iconset)/icon_\(base)x\(base).png")
    png(appIcon(base * 2), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}

// Menu bar template: light artwork -> opaque black, dark background -> transparent.
let glyphSize = 72
let tight = square.cropping(to: CGRect(x: 120, y: 0, width: H - 240, height: H))!  // trim side margins
let small = render(size: glyphSize) { ctx, s in
    ctx.draw(tight, in: CGRect(x: 0, y: 0, width: s, height: s))
}
let buf = NSBitmapImageRep(cgImage: small)
for y in 0..<glyphSize { for x in 0..<glyphSize {
    var px = [Int](repeating: 0, count: 4)
    buf.getPixel(&px, atX: x, y: y)
    let lum = Double(px[0] + px[1] + px[2]) / 3 / 255
    let a = min(max((lum - 0.22) / 0.45, 0), 1)
    var outPx: [Int] = [0, 0, 0, Int(a * 255)]
    buf.setPixel(&outPx, atX: x, y: y)
} }
try! buf.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/MenuBarIcon.png"))
print("ok")
