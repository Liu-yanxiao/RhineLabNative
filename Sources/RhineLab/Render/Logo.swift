import SwiftUI
import AppKit

/// The Rhine Lab mark (viewBox 310 × 145), shared by the UI and the printed label.
enum Logo {
    static let viewBox = CGSize(width: 310, height: 145)

    static func outline() -> CGPath {
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
        return p
    }

    static func symbols() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 44, y: 70)); p.addLine(to: CGPoint(x: 94, y: 70))
        p.move(to: CGPoint(x: 69, y: 45)); p.addLine(to: CGPoint(x: 69, y: 95))
        p.move(to: CGPoint(x: 219, y: 70)); p.addLine(to: CGPoint(x: 263, y: 70))
        return p
    }

    /// Draw into a CGContext whose origin is the top-left of `rect`.
    static func draw(in ctx: CGContext, rect: CGRect, color: CGColor) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / viewBox.width, y: rect.height / viewBox.height)
        ctx.setStrokeColor(color)
        ctx.setLineCap(.butt)
        ctx.setLineWidth(26)
        ctx.addPath(outline()); ctx.strokePath()
        ctx.setLineWidth(15)
        ctx.addPath(symbols()); ctx.strokePath()
        ctx.restoreGState()
    }
}

struct LogoMark: View {
    var color: Color = Color(red: 0.09, green: 0.09, blue: 0.075)
    var body: some View {
        Canvas { context, size in
            let sx = size.width / Logo.viewBox.width, sy = size.height / Logo.viewBox.height
            let t = CGAffineTransform(scaleX: sx, y: sy)
            context.stroke(Path(Logo.outline()).applying(t), with: .color(color), lineWidth: 26 * sx)
            context.stroke(Path(Logo.symbols()).applying(t), with: .color(color), lineWidth: 15 * sx)
        }
        .aspectRatio(Logo.viewBox.width / Logo.viewBox.height, contentMode: .fit)
    }
}
