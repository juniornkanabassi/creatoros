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

// Short: the saved Shorts mark centred on a white tile, at the same visual weight as the Live mark.
try render("short-icon.png") { context, rect in
    let tileRect = tile(context, rect: rect, fill: .white)
    guard let mark = shortsMark, let cg = mark.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let side = tileRect.width * 0.62
    let aspect = CGFloat(cg.width) / CGFloat(cg.height)
    let drawSize = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
    let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
    context.setShouldAntialias(true); context.interpolationQuality = .high
    context.draw(cg, in: CGRect(origin: origin, size: drawSize))
}
