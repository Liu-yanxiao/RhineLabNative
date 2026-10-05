// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Apple icon grid: 824-pt tile inside a 1024-pt canvas.
        let tile = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
        let radius = tile.width * 0.2237
        let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.957, green: 0.941, blue: 0.918, alpha: 1),
            CGColor(red: 0.847, green: 0.824, blue: 0.784, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

        // A frosted glass card standing in the tile.
        let card = CGRect(x: tile.minX + tile.width * 0.14, y: tile.minY + tile.height * 0.22,
                          width: tile.width * 0.72, height: tile.height * 0.56)
        let cardPath = CGPath(roundedRect: card, cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.035, color: CGColor(gray: 0.25, alpha: 0.25))
        ctx.addPath(cardPath); ctx.setFillColor(CGColor(red: 1, green: 0.995, blue: 0.985, alpha: 0.78)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(cardPath); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(s * 0.004); ctx.strokePath()

        // Rhine Lab mark (viewBox 310 × 145).
        let mark = CGRect(x: card.minX + card.width * 0.14, y: card.midY - card.width * 0.72 * 0.5 * 145 / 310 * 0.95,
                          width: card.width * 0.72, height: card.width * 0.72 * 145 / 310)
        ctx.saveGState()
        ctx.translateBy(x: mark.minX, y: mark.maxY)
        ctx.scaleBy(x: mark.width / 310, y: -mark.height / 145)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 156, y: 75))
        p.addCurve(to: CGPoint(x: 70, y: 15), control1: CGPoint(x: 127, y: 48), control2: CGPoint(x: 103, y: 15))
        p.addCurve(to: CGPoint(x: 15, y: 70), control1: CGPoint(x: 37, y: 15), control2: CGPoint(x: 15, y: 39))
        p.addCurve(to: CGPoint(x: 70, y: 128), control1: CGPoint(x: 15, y: 101), control2: CGPoint(x: 38, y: 128))
        p.addCurve(to: CGPoint(x: 176, y: 52), control1: CGPoint(x: 103, y: 128), control2: CGPoint(x: 127, y: 96))
        p.move(to: CGPoint(x: 155, y: 75))
        p.addCurve(to: CGPoint(x: 240, y: 128), control1: CGPoint(x: 182, y: 99), control2: CGPoint(x: 208, y: 128))
        p.addCurve(to: CGPoint(x: 295, y: 73), control1: CGPoint(x: 273, y: 128), control2: CGPoint(x: 295, y: 105))
        p.addCurve(to: CGPoint(x: 240, y: 15), control1: CGPoint(x: 295, y: 41), control2: CGPoint(x: 273, y: 15))
        p.addCurve(to: CGPoint(x: 192, y: 38), control1: CGPoint(x: 221, y: 15), control2: CGPoint(x: 207, y: 23))
        ctx.setStrokeColor(CGColor(red: 0.09, green: 0.09, blue: 0.075, alpha: 1))
        ctx.setLineWidth(26); ctx.addPath(p); ctx.strokePath()
        let g = CGMutablePath()
        g.move(to: CGPoint(x: 44, y: 70)); g.addLine(to: CGPoint(x: 94, y: 70))
        g.move(to: CGPoint(x: 69, y: 45)); g.addLine(to: CGPoint(x: 69, y: 95))
        g.move(to: CGPoint(x: 219, y: 70)); g.addLine(to: CGPoint(x: 263, y: 70))
        ctx.setLineWidth(15); ctx.addPath(g); ctx.strokePath()
        ctx.restoreGState()

        // Amber indicator, as on the archive cards.
        ctx.setFillColor(CGColor(red: 0.929, green: 0.51, blue: 0.106, alpha: 1))
        let dot = s * 0.026
        ctx.fillEllipse(in: CGRect(x: card.maxX - dot * 2.6, y: card.maxY - dot * 2.6, width: dot, height: dot))
        ctx.restoreGState()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run(); task.waitUntilExit()
print("Resources/AppIcon.icns written")
