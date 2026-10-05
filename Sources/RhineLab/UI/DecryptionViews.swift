import SwiftUI
import CoreText
import AppKit

/// Scan lines, corner marks and the confidentiality label drawn over the extracted card.
struct InspectionOverlay: View {
    @EnvironmentObject var model: AppModel
    @State private var finished = false
    private let ink = Color(red: 0.141, green: 0.133, blue: 0.122)   // #24221f

    /// Map normalised device coordinates of the 3D view into the 1920 × 1080 interface stage.
    private static func stagePoint(_ p: SIMD2<Float>, _ size: CGSize, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: (CGFloat((p.x + 1) / 2) * size.width - size.width / 2) / scale + 960,
                y: (CGFloat((1 - p.y) / 2) * size.height - size.height / 2) / scale + 540)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: finished)) { _ in
            let size = model.windowSize
            let o = model.engine.overlay(aspect: Float(size.width / max(1, size.height)))
            let scale = min(size.width / 1920, size.height / 1080)
            let stage = { (p: SIMD2<Float>) -> CGPoint in Self.stagePoint(p, size, scale) }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var path = Path()
                    for (a, b) in o.segments { path.move(to: stage(a)); path.addLine(to: stage(b)) }
                    context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))
                    if o.frame.markers > 0 {
                        for c in o.corners {
                            let p = stage(c)
                            context.fill(Path(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(ink.opacity(Double(o.frame.markers))))
                        }
                    }
                    if o.frame.point > 0 {
                        let p = stage(o.center)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 1.8, y: p.y - 1.8, width: 3.6, height: 3.6)), with: .color(ink.opacity(Double(o.frame.point))))
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("CONFIDENTIALITY:").font(Theme.font(23, .semibold))
                    Text("GENERAL BUSINESS USE").font(Theme.font(30, .bold)).opacity(Double(o.frame.labelValue))
                }
                .foregroundStyle(ink).opacity(Double(o.frame.label))
                .offset(x: 1202, y: 499)
            }
            .allowsHitTesting(false)
            .onChange(of: o.finished) { _, done in if done { finished = true } }
            .onAppear { if o.finished { finished = true } }
        }
    }
}

/// Text with black redaction bars that slide away line by line while the glass clears.
struct RedactedText: View {
    let text: String
    var weight: Theme.Weight = .regular
    let size: CGFloat
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var width: CGFloat? = nil
    var color: Color = Theme.ink
    let progress: Float
    var order = 0
    var count = 12

    private struct Line { var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat }

    private var lines: [Line] {
        guard progress < 1 else { return [] }
        let font = NSFont(name: weight.rawValue, size: size) ?? .systemFont(ofSize: size)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attr = NSAttributedString(string: text, attributes: [.font: font, .kern: tracking, .paragraphStyle: style])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let limit = width ?? 4000
        let big: CGFloat = 10000
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: limit, height: big), transform: nil), nil)
        let ctLines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        guard !ctLines.isEmpty else { return [] }
        let topOffset = big - origins[0].y - CTFontGetAscent(font)
        return ctLines.enumerated().map { i, line in
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
            return Line(x: 0, y: big - origins[i].y - asc - topOffset, w: min(w, limit), h: asc + desc)
        }
    }

    var body: some View {
        Text(text).font(Theme.font(size, weight)).tracking(tracking).lineSpacing(lineSpacing)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let t = bar(i)
                        Color(red: 0.125, green: 0.133, blue: 0.113)
                            .frame(width: line.w + 2, height: line.h + 2)
                            .offset(x: t * (line.w + 2) * 1.01)
                            .frame(width: line.w + 2, height: line.h + 2, alignment: .leading)
                            .clipped()
                            .offset(x: line.x - 1, y: line.y - 1)
                    }
                }
            }
    }

    /// Brief acceleration, decisive departure, long deceleration; no bounce.
    private func bar(_ lineIndex: Int) -> CGFloat {
        let delay = Double(min(order + lineIndex, count)) / Double(max(1, count)) * 0.22
        let t = min(1, max(0, (Double(progress) - delay) / 0.78))
        return t < 0.2 ? 0.4 * pow(t / 0.2, 2) : 1 - 0.6 * pow((1 - t) / 0.8, 16.0 / 3.0)
    }
}
