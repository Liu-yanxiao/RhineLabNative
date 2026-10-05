import AppKit
import CoreGraphics

/// The printed label on a card, drawn once per archive number.
enum LabelImage {
    static let width = 1024, height = 440
    private static var cache: [Int: CGImage] = [:]

    static func image(for index: Int) -> CGImage {
        if let hit = cache[index] { return hit }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        func text(_ s: String, _ x: CGFloat, baseline: CGFloat, size: CGFloat, bold: Bool, color: NSColor) {
            let font = NSFont(name: bold ? "MiSans-Bold" : "MiSans-Regular", size: size) ?? .systemFont(ofSize: size)
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
                .draw(at: NSPoint(x: x, y: baseline - font.ascender))
        }
        color(0xe6e2d9).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ink = color(0x171713)
        ink.setFill()
        ctx.fill(CGRect(x: 12, y: 12, width: 1000, height: 6))
        ctx.fill(CGRect(x: 12, y: 419, width: 1000, height: 3))
        text("RHINE LAB, LLC.", 22, baseline: 116, size: 81, bold: true, color: ink)
        text("INTERNAL DATABASE", 25, baseline: 174, size: 32, bold: false, color: color(0x878476))
        text("NO." + String(format: "%03d", index + 1), 22, baseline: 360, size: 130, bold: true, color: ink)
        ink.setFill(); ctx.fill(CGRect(x: 782, y: 32, width: 221, height: 39))
        text("R L / I S", 809, baseline: 61, size: 24, bold: false, color: color(0xeee9de))
        text("INFO", 830, baseline: 143, size: 64, bold: true, color: ink)
        Logo.draw(in: ctx, rect: CGRect(x: 790, y: 242, width: 210, height: 98), color: ink.cgColor)
        let image = ctx.makeImage()!
        cache[index] = image
        return image
    }
}
