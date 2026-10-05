import SwiftUI

/// Condensed opening sequence: white field → mark drawn → identity → permission → welcome.
struct BootView: View {
    @EnvironmentObject var model: AppModel
    @State private var start = Date()

    private let total = 7.2
    private func ease(_ x: Double) -> Double { Double(Motion.smooth(Float(x))) }
    private func span(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            ZStack {
                Rectangle().fill(t < 0.6 ? Color.white : Color(red: 0.93, green: 0.92, blue: 0.9))
                    .opacity(1 - ease(span(t, 6.5, total)))
                    .animation(.easeOut(duration: 0.6), value: t < 0.6)

                // Identity: drawn mark + status line
                ZStack(alignment: .topLeading) {
                    BootMark(progress: ease(span(t, 0.7, 2.4)), symbols: ease(span(t, 2.2, 2.8)))
                        .frame(width: 345, height: 161).offset(x: 524, y: 452)
                    Text("RHINE · LAB").font(Theme.font(16, .bold)).tracking(22).offset(x: 540, y: 628)
                        .opacity(ease(span(t, 2.4, 3.0)))
                    let message = "ID CONFIRMED : JOYCE MOORE"
                    let count = Int(span(t, 2.8, 3.6) * Double(message.count))
                    HStack(spacing: 8) { Text("▪"); Text(String(message.prefix(count))) }
                        .font(Theme.font(14)).tracking(0.6).offset(x: 936, y: 520)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(Theme.ink).opacity(1 - ease(span(t, 4.0, 4.5)))

                // Permission scan
                let scan = span(t, 4.2, 6.4)
                ZStack {
                    Circle().stroke(Theme.ink, lineWidth: 2).frame(width: 300, height: 300).scaleEffect(0.6 + 0.4 * ease(span(t, 4.2, 5.0)))
                    Circle().trim(from: 0, to: ease(span(t, 4.2, 5.2))).stroke(Theme.ink, lineWidth: 2)
                        .frame(width: 220, height: 220).rotationEffect(.degrees(scan * 540))
                    ForEach(0..<2, id: \.self) { i in
                        Circle().fill(Color(red: 0.929, green: 0.51, blue: 0.106)).frame(width: 16, height: 16)
                            .offset(y: -150).rotationEffect(.degrees(scan * 720 + Double(i) * 180))
                    }
                    Circle().fill(Theme.ink).frame(width: 10, height: 10)
                    Text("PERMISSION AUTHORIZED").font(Theme.font(14)).tracking(1.5).offset(y: 210)
                }
                .foregroundStyle(Theme.ink)
                .opacity(ease(span(t, 4.2, 4.7)) * (1 - ease(span(t, 5.9, 6.4))))

                // Welcome
                VStack(spacing: 14) {
                    Text("WELCOME TO").font(Theme.font(18)).tracking(3)
                    Text("RHINE LAB.LLC.").font(Theme.font(54, .bold)).tracking(2)
                    Text("INTERNAL DATABASE").font(Theme.font(14)).tracking(2.4).foregroundStyle(Theme.muted)
                }
                .foregroundStyle(Theme.ink).offset(y: 40 * (1 - ease(span(t, 5.9, 6.6))))
                .opacity(ease(span(t, 5.9, 6.5)) * (1 - ease(span(t, 6.8, total))))
            }
            .onChange(of: t >= total) { _, done in if done { model.finishBoot() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onChange(of: model.bootID) { _, _ in start = Date() }
        .onAppear { start = Date() }
    }
}

/// The mark drawn as one continuous stroke, then its + and − glyphs.
private struct BootMark: View {
    let progress: Double
    let symbols: Double
    var body: some View {
        Canvas { context, size in
            let sx = size.width / Logo.viewBox.width, sy = size.height / Logo.viewBox.height
            let t = CGAffineTransform(scaleX: sx, y: sy)
            let contour = Path(BootMark.contour).trimmedPath(from: 0, to: progress).applying(t)
            context.stroke(contour, with: .color(Theme.ink), lineWidth: 26 * sx)
            var glyph = context
            glyph.opacity = symbols
            glyph.stroke(Path(Logo.symbols()).applying(t), with: .color(Theme.ink), lineWidth: 15 * sx)
        }
    }

    static let contour: CGPath = {
        let p = CGMutablePath()
        func c(_ a: Double, _ b: Double, _ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double, to: CGPoint) {
            p.addCurve(to: to, control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
        }
        p.move(to: CGPoint(x: 295, y: 73))
        p.addCurve(to: CGPoint(x: 240, y: 15), control1: CGPoint(x: 295, y: 41), control2: CGPoint(x: 273, y: 15))
        p.addCurve(to: CGPoint(x: 192, y: 38), control1: CGPoint(x: 221, y: 15), control2: CGPoint(x: 207, y: 23))
        p.addCurve(to: CGPoint(x: 176, y: 52), control1: CGPoint(x: 186, y: 43), control2: CGPoint(x: 181, y: 47))
        p.addCurve(to: CGPoint(x: 70, y: 128), control1: CGPoint(x: 127, y: 96), control2: CGPoint(x: 103, y: 128))
        p.addCurve(to: CGPoint(x: 15, y: 70), control1: CGPoint(x: 38, y: 128), control2: CGPoint(x: 15, y: 101))
        p.addCurve(to: CGPoint(x: 70, y: 15), control1: CGPoint(x: 15, y: 39), control2: CGPoint(x: 37, y: 15))
        p.addCurve(to: CGPoint(x: 156, y: 75), control1: CGPoint(x: 103, y: 15), control2: CGPoint(x: 127, y: 48))
        p.addCurve(to: CGPoint(x: 240, y: 128), control1: CGPoint(x: 182, y: 99), control2: CGPoint(x: 208, y: 128))
        p.addCurve(to: CGPoint(x: 295, y: 73), control1: CGPoint(x: 273, y: 128), control2: CGPoint(x: 295, y: 105))
        p.closeSubpath()
        return p
    }()
}
