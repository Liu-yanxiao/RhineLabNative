import AppKit

/// A real, bounded-size cover when available; a quiet typographic placeholder otherwise.
enum MusicPrint {
    static func image(for index: Int) -> CGImage {
        if let image = MusicArtwork.image(index) { return image }
        let items = MusicCatalog.items
        let item = items[min(max(0, index), items.count - 1)]
        let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: 512); ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }
        ctx.setFillColor(NSColor(srgbRed: 0.9, green: 0.89, blue: 0.85, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let ink = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.11, alpha: 1)
        let font = NSFont(name: "MiSans-Demibold", size: 23) ?? .systemFont(ofSize: 23)
        NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: ink]).draw(in: CGRect(x: 40, y: 410, width: 430, height: 68))
        NSAttributedString(string: "RHINE / MUSIC", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink]).draw(at: CGPoint(x: 40, y: 42))
        ctx.setStrokeColor(ink.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(1)
        for n in 0..<5 {
            let inset = CGFloat(n * 21)
            ctx.strokeEllipse(in: CGRect(x: 125 + inset, y: 114 + inset, width: 260 - inset * 2, height: 260 - inset * 2))
        }
        ctx.move(to: CGPoint(x: 40, y: 395)); ctx.addLine(to: CGPoint(x: 472, y: 395)); ctx.strokePath()
        return ctx.makeImage()!
    }
}
