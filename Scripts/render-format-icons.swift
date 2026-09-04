// Renders the Long and Short format icons in the same app-tile style as the Live icon, so the four formats read
// as one family beside Apple's own icons. Long: YouTube's play badge, white on a red tile. Short: the Shorts mark
// (the existing saved icon, supplied as a PNG) on a white tile.
// Usage: swift Scripts/render-format-icons.swift <shorts-mark.png> <output folder> [size]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { print("usage: render-format-icons.swift <shorts-mark.png> <output folder> [size]"); exit(2) }
let shortsMark = NSImage(contentsOfFile: arguments[1])
let outputFolder = URL(fileURLWithPath: arguments[2])
let size = CGFloat(arguments.count > 3 ? Double(arguments[3]) ?? 1024 : 1024)

func tile(_ context: CGContext, rect: CGRect, fill: NSColor) -> CGRect {
    let inset = size * 0.06
    let tile = rect.insetBy(dx: inset, dy: inset)
    let radius = tile.width * 0.2237
    let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    context.addPath(path); context.setFillColor(fill.cgColor); context.fillPath()
    context.restoreGState()
    context.addPath(path); context.setStrokeColor(NSColor(white: 0, alpha: 0.08).cgColor); context.setLineWidth(size * 0.004); context.strokePath()
    return tile
}

func render(_ name: String, draw: @escaping (CGContext, CGRect) -> Void) throws {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        draw(context, rect); return true
    }
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "render", code: 1) }
    let url = outputFolder.appendingPathComponent(name)
    try png.write(to: url)
    print("Wrote \(url.path)")
}

// Long: YouTube red tile with the white play badge and a red triangle, the mark everyone recognises at any size.
try render("long-icon.png") { context, rect in
    let red = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1)
    _ = tile(context, rect: rect, fill: red)
    let badge = CGRect(x: rect.midX - size * 0.30, y: rect.midY - size * 0.21, width: size * 0.60, height: size * 0.42)
    context.addPath(CGPath(roundedRect: badge, cornerWidth: badge.height * 0.3, cornerHeight: badge.height * 0.3, transform: nil))
    context.setFillColor(NSColor.white.cgColor); context.fillPath()
    let h = badge.height * 0.42, w = h * 0.9
    let x = badge.midX - w * 0.4
    context.move(to: CGPoint(x: x, y: badge.midY - h / 2))
    context.addLine(to: CGPoint(x: x + w, y: badge.midY))
    context.addLine(to: CGPoint(x: x, y: badge.midY + h / 2))
    context.closePath(); context.setFillColor(red.cgColor); context.fillPath()
}

// Short: the Shorts mark in white on the same red tile, its inner triangle in red. The saved mark is red with a
// white triangle, so each pixel is remapped: red body to white, white triangle to red, edges in between.
try render("short-icon.png") { context, rect in
    let red = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1)
    let tileRect = tile(context, rect: rect, fill: red)
    guard let mark = shortsMark, let cg = mark.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let a = Double(pixels[i + 3]); if a == 0 { continue }
        // Whiteness from the green and blue channels, un-premultiplied: the red body has none, the triangle has all.
        let t = min(1, (Double(pixels[i + 1]) + Double(pixels[i + 2])) / (2 * a))
        pixels[i] = UInt8(a)                       // red stays full in both white and red
        pixels[i + 1] = UInt8(a * (1 - t)); pixels[i + 2] = UInt8(a * (1 - t))
    }
    guard let recoloured = bitmap.makeImage() else { return }
    let side = tileRect.width * 0.62
    let aspect = CGFloat(width) / CGFloat(height)
    let drawSize = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
    let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
    context.interpolationQuality = .high
    context.draw(recoloured, in: CGRect(origin: origin, size: drawSize))
}

// Live: the broadcast mark in white on the red tile.
try render("live-icon.png") { context, rect in
    let red = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1)
    _ = tile(context, rect: rect, fill: red)
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: centre.x - size * 0.11, y: centre.y - size * 0.11, width: size * 0.22, height: size * 0.22))
    context.setStrokeColor(NSColor.white.cgColor); context.setLineCap(.round); context.setLineWidth(size * 0.052)
    let span = CGFloat.pi * 0.19
    for r in [size * 0.215, size * 0.33] {
        for side: CGFloat in [0, .pi] {
            context.addArc(center: centre, radius: r, startAngle: side - span, endAngle: side + span, clockwise: false)
            context.strokePath()
        }
    }
}
