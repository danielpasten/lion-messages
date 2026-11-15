// Draws the Lion Messages app icon (two glossy Aqua speech bubbles) as a 1024x1024 PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// A rounded speech bubble in `rect` with a curved tail at the bottom, pointing left or right.
func bubblePath(_ rect: NSRect, tailRight: Bool) -> NSBezierPath {
    let r = rect.height * 0.46
    let body = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    let tail = NSBezierPath()
    let s: CGFloat = tailRight ? 1 : -1
    let baseX = tailRight ? rect.maxX - rect.width * 0.34 : rect.minX + rect.width * 0.34
    let y = rect.minY + rect.height * 0.14
    let tip = NSPoint(x: baseX + s * rect.width * 0.22, y: rect.minY - rect.height * 0.20)
    tail.move(to: NSPoint(x: baseX - s * rect.width * 0.09, y: y))
    tail.curve(to: tip,
               controlPoint1: NSPoint(x: baseX - s * rect.width * 0.02, y: rect.minY - rect.height * 0.06),
               controlPoint2: NSPoint(x: baseX + s * rect.width * 0.08, y: rect.minY - rect.height * 0.17))
    tail.curve(to: NSPoint(x: baseX + s * rect.width * 0.11, y: y),
               controlPoint1: NSPoint(x: baseX + s * rect.width * 0.15, y: rect.minY - rect.height * 0.12),
               controlPoint2: NSPoint(x: baseX + s * rect.width * 0.11, y: rect.minY - rect.height * 0.02))
    tail.close()
    // A true union, so the outline has no seams where the tail meets the body.
    return NSBezierPath(cgPath: body.cgPath.union(tail.cgPath))
}

func drawBubble(_ rect: NSRect, tailRight: Bool, top: Int, mid: Int, bottom: Int, border: Int) {
    let path = bubblePath(rect, tailRight: tailRight)

    // Drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(deviceWhite: 0, alpha: 0.45)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    rgb(border).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gel body.
    NSGradient(colorsAndLocations: (rgb(top), 0), (rgb(mid), 0.6), (rgb(bottom), 1))!
        .draw(in: path, angle: -90)

    // Top gloss highlight.
    let inset = rect.width * 0.06
    let gloss = NSRect(x: rect.minX + inset, y: rect.midY - rect.height * 0.02,
                       width: rect.width - inset * 2, height: rect.height * 0.47)
    let glossPath = NSBezierPath(roundedRect: gloss, xRadius: gloss.height * 0.8, yRadius: gloss.height * 0.8)
    NSGradient(starting: NSColor(deviceWhite: 1, alpha: 0.85), ending: NSColor(deviceWhite: 1, alpha: 0.08))!
        .draw(in: glossPath, angle: -90)

    // Border.
    rgb(border).setStroke()
    path.lineWidth = 7
    path.lineJoinStyle = .round
    path.stroke()
}

// Back bubble: incoming, gray gel.
drawBubble(NSRect(x: 96, y: 560, width: 560, height: 330), tailRight: false,
           top: 0xf4f4f4, mid: 0xcfcfcf, bottom: 0xececec, border: 0x8a8a8a)
// Front bubble: outgoing, Aqua blue gel.
drawBubble(NSRect(x: 260, y: 230, width: 680, height: 420), tailRight: true,
           top: 0x8ec6ff, mid: 0x3a8ae8, bottom: 0x7cc0fb, border: 0x1d55a6)

NSGraphicsContext.current?.flushGraphics()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
