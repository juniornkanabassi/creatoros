// Original, code-native app artwork. Regenerate with: swift Scripts/render-icon.swift <output.png>
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Supply an output PNG path") }
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
func colour(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow(); tileShadow.shadowColor = colour(0x071A55, alpha: 0.28)
tileShadow.shadowBlurRadius = 22; tileShadow.shadowOffset = NSSize(width: 0, height: -12); tileShadow.set()
colour(0x2453D4).setFill(); tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: colour(0x3678F2), ending: colour(0x193DA6))!.draw(in: tile, angle: -90)
colour(0xFFFFFF, alpha: 0.15).setStroke(); tile.lineWidth = 3; tile.stroke()

// Two offset reusable sheets behind the primary folder.
rounded(NSRect(x: 256, y: 466, width: 544, height: 265), radius: 37, fill: colour(0xCCDDFF, alpha: 0.56))
rounded(NSRect(x: 232, y: 416, width: 560, height: 274), radius: 39, fill: colour(0xE5EFFF, alpha: 0.85))

// Folder back with its recognisable tab, with no typography or borrowed artwork.
let folder = NSBezierPath()
folder.move(to: NSPoint(x: 204, y: 304))
folder.line(to: NSPoint(x: 204, y: 632))
folder.curve(to: NSPoint(x: 246, y: 674), controlPoint1: NSPoint(x: 204, y: 657), controlPoint2: NSPoint(x: 220, y: 674))
folder.line(to: NSPoint(x: 406, y: 674))
folder.curve(to: NSPoint(x: 443, y: 655), controlPoint1: NSPoint(x: 424, y: 674), controlPoint2: NSPoint(x: 431, y: 669))
folder.line(to: NSPoint(x: 481, y: 608))
folder.line(to: NSPoint(x: 778, y: 608))
folder.curve(to: NSPoint(x: 820, y: 566), controlPoint1: NSPoint(x: 802, y: 608), controlPoint2: NSPoint(x: 820, y: 592))
folder.line(to: NSPoint(x: 820, y: 304))
folder.curve(to: NSPoint(x: 774, y: 258), controlPoint1: NSPoint(x: 820, y: 276), controlPoint2: NSPoint(x: 802, y: 258))
folder.line(to: NSPoint(x: 250, y: 258))
folder.curve(to: NSPoint(x: 204, y: 304), controlPoint1: NSPoint(x: 222, y: 258), controlPoint2: NSPoint(x: 204, y: 276))
folder.close()
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = colour(0x08194F, alpha: 0.38)
shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
colour(0xFBF9ED).setFill(); folder.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: colour(0xFFFEF7), ending: colour(0xE7EEFA))!.draw(in: folder, angle: -90)
rounded(NSRect(x: 228, y: 553, width: 568, height: 5), radius: 2.5, fill: colour(0xB9CCE8, alpha: 0.7))

// Three original cards fan out of the folder mouth: editing (purple, timeline strip),
// graphics (blue, stacked layers) and streaming (charcoal, record dot). They borrow the
// familiar colours of the apps Junior edits, designs and streams with, not their logos.
func card(centre: NSPoint, angle: CGFloat, fill: NSColor, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: centre.x, yBy: centre.y)
    transform.rotate(byDegrees: angle)
    transform.concat()
    let cardShadow = NSShadow(); cardShadow.shadowColor = colour(0x08194F, alpha: 0.35)
    cardShadow.shadowBlurRadius = 14; cardShadow.shadowOffset = NSSize(width: 0, height: -8); cardShadow.set()
    rounded(NSRect(x: -74, y: -96, width: 148, height: 192), radius: 26, fill: fill)
    NSShadow().set()
    colour(0xFFFFFF, alpha: 0.18).setStroke()
    let outline = NSBezierPath(roundedRect: NSRect(x: -74, y: -96, width: 148, height: 192), xRadius: 26, yRadius: 26)
    outline.lineWidth = 3; outline.stroke()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}
// Editing card, left, tilted outwards: a timeline of clips.
card(centre: NSPoint(x: 356, y: 540), angle: 12, fill: colour(0x6A3DDB)) {
    for (index, width) in [96, 60, 80].enumerated() {
        rounded(NSRect(x: -50, y: 40 - CGFloat(index) * 34, width: CGFloat(width), height: 20), radius: 6, fill: colour(0xFFFFFF, alpha: index == 0 ? 0.95 : 0.7))
    }
    rounded(NSRect(x: -2, y: -70, width: 4, height: 140), radius: 2, fill: colour(0xFFD166))
}
// Streaming card, centre, upright and tallest: a record dot with a signal arc.
card(centre: NSPoint(x: 512, y: 570), angle: 0, fill: colour(0x2B2F36)) {
    colour(0xFFFFFF, alpha: 0.85).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: -44, y: -44, width: 88, height: 88)); ring.lineWidth = 8; ring.stroke()
    colour(0xE94F4F).setFill(); NSBezierPath(ovalIn: NSRect(x: -22, y: -22, width: 44, height: 44)).fill()
}
// Graphics card, right, tilted the other way: three offset layers.
card(centre: NSPoint(x: 668, y: 540), angle: -12, fill: colour(0x1F6FD6)) {
    for index in 0..<3 {
        rounded(NSRect(x: -46 + CGFloat(index) * 12, y: -36 + CGFloat(index) * 26, width: 80, height: 34), radius: 9, fill: colour(0xFFFFFF, alpha: 0.55 + CGFloat(index) * 0.2))
    }
}

// The folder front, drawn over the cards so they appear to rise out of it.
let front = NSBezierPath(roundedRect: NSRect(x: 204, y: 258, width: 616, height: 222), xRadius: 46, yRadius: 46)
NSGraphicsContext.saveGraphicsState()
let frontShadow = NSShadow(); frontShadow.shadowColor = colour(0x08194F, alpha: 0.30)
frontShadow.shadowBlurRadius = 18; frontShadow.shadowOffset = NSSize(width: 0, height: 10); frontShadow.set()
colour(0xFBF9ED).setFill(); front.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: colour(0xFFFEF7), ending: colour(0xE7EEFA))!.draw(in: front, angle: -90)

// A restrained inset creation mark remains clear even in the small icon sizes.
rounded(NSRect(x: 606, y: 300, width: 160, height: 160), radius: 42, fill: colour(0x15469A))
rounded(NSRect(x: 626, y: 320, width: 120, height: 120), radius: 29, fill: colour(0x75E5C4))
rounded(NSRect(x: 674, y: 342, width: 24, height: 76), radius: 8, fill: colour(0x103D73))
rounded(NSRect(x: 648, y: 368, width: 76, height: 24), radius: 8, fill: colour(0x103D73))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
