// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // A single midnight instrument tile: clear at Dock size, with no nested card.
        let tile = CGRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
        let radius = tile.width * 0.2237
        let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.028, color: CGColor(gray: 0, alpha: 0.32))
        ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.025, green: 0.06, blue: 0.10, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.17, green: 0.24, blue: 0.30, alpha: 1),
            CGColor(red: 0.045, green: 0.085, blue: 0.14, alpha: 1),
            CGColor(red: 0.018, green: 0.035, blue: 0.065, alpha: 1)] as CFArray, locations: [0, 0.52, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        // Quiet permission-scan arcs, visible in large icons but subordinate to the mark.
        if size >= 64 {
            ctx.setStrokeColor(CGColor(red: 0.72, green: 0.82, blue: 0.91, alpha: 0.10))
            ctx.setLineWidth(max(0.7, s * 0.0015))
            for fraction in [0.48, 0.61] {
                let r = tile.width * fraction
                ctx.strokeEllipse(in: CGRect(x: tile.maxX - r * 1.36, y: tile.minY - r * 0.6, width: r * 2, height: r * 2))
            }
        }
        // Rhine Lab mark (viewBox 310 × 145).
        let mark = CGRect(x: tile.midX - tile.width * 0.39, y: tile.midY - tile.width * 0.78 * 145 / 310 / 2,
                          width: tile.width * 0.78, height: tile.width * 0.78 * 145 / 310)
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
        ctx.setStrokeColor(CGColor(red: 0.92, green: 0.95, blue: 0.97, alpha: 1))
        ctx.setLineWidth(26); ctx.addPath(p); ctx.strokePath()
        let g = CGMutablePath()
        g.move(to: CGPoint(x: 44, y: 70)); g.addLine(to: CGPoint(x: 94, y: 70))
        g.move(to: CGPoint(x: 69, y: 45)); g.addLine(to: CGPoint(x: 69, y: 95))
        g.move(to: CGPoint(x: 219, y: 70)); g.addLine(to: CGPoint(x: 263, y: 70))
        ctx.setLineWidth(15); ctx.addPath(g); ctx.strokePath()
        ctx.restoreGState()

        // The film’s amber registration square, plus a hairline under the mark.
        ctx.setFillColor(CGColor(red: 0.86, green: 0.64, blue: 0.37, alpha: 1))
        let dot = max(1, s * 0.025)
        ctx.fill(CGRect(x: tile.maxX - tile.width * 0.16 - dot, y: tile.maxY - tile.height * 0.16 - dot, width: dot, height: dot))
        if size >= 64 {
            ctx.setStrokeColor(CGColor(red: 0.80, green: 0.87, blue: 0.91, alpha: 0.22))
            ctx.setLineWidth(max(0.5, s * 0.001))
            ctx.move(to: CGPoint(x: tile.minX + tile.width * 0.24, y: tile.minY + tile.height * 0.22))
            ctx.addLine(to: CGPoint(x: tile.maxX - tile.width * 0.24, y: tile.minY + tile.height * 0.22)); ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.addPath(shape); ctx.setStrokeColor(CGColor(red: 0.74, green: 0.83, blue: 0.91, alpha: 0.30))
        ctx.setLineWidth(max(0.5, s * 0.0015)); ctx.strokePath()
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
