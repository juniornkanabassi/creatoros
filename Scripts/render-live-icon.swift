// Renders the Live format icon: Junior's red broadcast mark (a dot with two arcs each side) on a white
// macOS-style rounded square, so it reads from across the room and sits beside the other format icons
// like an app icon. Usage: swift Scripts/render-live-icon.swift <output.png> [size]
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "live-icon.png"
let size = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 1024 : 1024)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    // Apple's icon grid: the tile sits inside a margin, corners a little over a fifth of the tile.
    let inset = size * 0.06
    let tile = rect.insetBy(dx: inset, dy: inset)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    context.addPath(tilePath); context.setFillColor(NSColor.white.cgColor); context.fillPath()
    context.restoreGState()
    context.addPath(tilePath); context.setStrokeColor(NSColor(white: 0, alpha: 0.08).cgColor); context.setLineWidth(size * 0.004); context.strokePath()

    let red = NSColor(calibratedRed: 0.925, green: 0.325, blue: 0.31, alpha: 1).cgColor
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    context.setFillColor(red)
    context.fillEllipse(in: CGRect(x: centre.x - size * 0.11, y: centre.y - size * 0.11, width: size * 0.22, height: size * 0.11 * 2))
    context.setStrokeColor(red); context.setLineCap(.round); context.setLineWidth(size * 0.052)
    let span = CGFloat.pi * 0.19
    for r in [size * 0.215, size * 0.33] {
        for side: CGFloat in [0, .pi] {
            context.addArc(center: centre, radius: r, startAngle: side - span, endAngle: side + span, clockwise: false)
            context.strokePath()
        }
    }
    return true
}

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not render.\n".utf8)); exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output), \(Int(size)) px")
