import SwiftUI

/// The opening, frame-accurate to the original footage: typed access request, the mark drawn as
/// one stroke, identity lines, the permission scan rings, the welcome card and the white-out.
/// Geometry is in 1920 × 1080 stage points; the clock lives in the model so the sounds match.
struct BootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        TimelineView(.animation) { context in
            let s = BootMotion.state(appTime: model.bootTime(at: context.date))
            ZStack(alignment: .topLeading) {
                BootBackdrop(t: s.t).opacity(s.backgroundOpacity)

                BrandHeader(boot: s.brand).place(left: 59, top: 114)
                PoweredBy()
                    .mask(alignment: .leading) {
                        GeometryReader { g in Rectangle().frame(width: g.size.width * CGFloat(s.poweredLetters) / 19) }
                    }
                    .opacity(s.poweredLetters > 0 ? 1 : 0)

                LetteringText(keys: ["access"], text: s.access, size: 18, color: pal.ink)
                    .offset(x: 800, y: 532)
                    .opacity(s.accessOpacity)

                BootLogo(track: s.logo, letters: s.logoLetters, color: pal.ink)
                    .frame(width: 296, height: 177)
                    .offset(x: 518 + s.logo.offsetX, y: 463)
                    .opacity(s.logoOpacity)

                HStack(alignment: .center, spacing: 10) {
                    Text("▪").font(Theme.font(14)).foregroundStyle(pal.ink)
                    LetteringText(keys: ["identity", "request", "processing", "processingGlitch"], text: s.auth,
                                  size: 21.35, tracking: -0.00909 * 21.35, color: pal.ink)
                }
                .frame(height: 26)
                .offset(x: 931, y: 527)
                .opacity(s.authOpacity)

                if s.scanVisible { ScanLayer(state: s) }
                if s.welcomeVisible { WelcomeLayer(state: s).offset(x: 720, y: 403) }

                Rectangle().fill(pal.flash).opacity(s.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Warm grey field with the faint white contour lines, drifting slowly as the opening plays.
private struct BootBackdrop: View {
    @Environment(\.palette) private var pal
    var t: Double = 6

    var body: some View {
        ZStack {
            RadialGradient(stops: [
                .init(color: pal.bootInner, location: 0),
                .init(color: pal.bootOuter, location: 0.76),
                .init(color: pal.bootRim, location: 1)],
                           center: UnitPoint(x: 0.51, y: 0.48), startRadius: 0, endRadius: 1300)
            Canvas { context, _ in
                func curve(_ p: inout Path, _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat, _ x: CGFloat, _ y: CGFloat) {
                    p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
                }
                var left = Path()
                left.move(to: CGPoint(x: -210, y: 705))
                curve(&left, -45, 705, 182, 704, 247, 567)
                curve(&left, 337, 377, 99, 306, 4, 435)
                curve(&left, -91, 564, 27, 680, 169, 631)
                curve(&left, 309, 584, 227, 314, 279, 111)
                curve(&left, 331, -92, 568, -113, 568, -113)
                var right = Path()
                right.move(to: CGPoint(x: 1560, y: -80))
                curve(&right, 1374, 114, 1671, 168, 1601, 323)
                curve(&right, 1531, 478, 1371, 367, 1431, 480)
                curve(&right, 1491, 593, 1692, 666, 1559, 787)
                curve(&right, 1426, 908, 1329, 886, 1498, 1130)
                for path in [left, right] { context.stroke(path, with: .color(pal.contour), lineWidth: 3) }
                for r in [346.0, 348.0] {
                    context.stroke(Path(ellipseIn: CGRect(x: 1450 - r, y: 648 - r, width: r * 2, height: r * 2)),
                                   with: .color(pal.contour), lineWidth: 3)
                }
            }
            .opacity(0.15).blur(radius: 2)
            .scaleEffect(1.08)
            .offset(x: sin(t * 0.16) * 18, y: -(t - 6) * 5)
        }
        .frame(width: 1920, height: 1080)
        .clipped()
    }
}

/// The mark drawn as a moving segment of one closed contour, then its + and − glyphs and the
/// RHINE·LAB letters (web `.boot-logo`, viewBox 310 × 185 in a 296 × 177 box).
struct BootLogo: View {
    let track: BootLogoTrack
    let letters: String
    let color: Color

    static let contour: Path = {
        var p = Path()
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

    var body: some View {
        Canvas { context, size in
            let k = size.width / 310
            let scale = CGAffineTransform(scaleX: k, y: k)
            // Visible stroke from `start` to `start + length`, wrapping across the closing point.
            var a = track.start - floor(track.start)
            let b = a + track.length
            var segments: [Path] = []
            if track.length >= 0.999 {
                segments = [Self.contour]
            } else if b <= 1 {
                segments = [Self.contour.trimmedPath(from: a, to: b)]
            } else {
                segments = [Self.contour.trimmedPath(from: a, to: 1), Self.contour.trimmedPath(from: 0, to: b - 1)]
            }
            a = 0
            for segment in segments {
                context.stroke(segment.applying(scale), with: .color(color), style: StrokeStyle(lineWidth: track.strokeWidth * k, lineCap: .butt))
            }
            if track.symbolScale > 0 {
                var plus = Path()
                plus.move(to: CGPoint(x: 44, y: 70)); plus.addLine(to: CGPoint(x: 94, y: 70))
                plus.move(to: CGPoint(x: 69, y: 45)); plus.addLine(to: CGPoint(x: 69, y: 95))
                let plusT = CGAffineTransform(translationX: -69, y: -70)
                    .concatenating(CGAffineTransform(scaleX: track.symbolScale, y: track.symbolScale))
                    .concatenating(CGAffineTransform(rotationAngle: track.plusAngle * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: track.plusX, y: 70))
                context.stroke(plus.applying(plusT).applying(scale), with: .color(color), lineWidth: 15 * k)
                var minus = Path()
                minus.move(to: CGPoint(x: -track.minusWidth / 2, y: 0)); minus.addLine(to: CGPoint(x: track.minusWidth / 2, y: 0))
                let minusT = CGAffineTransform(scaleX: track.symbolScale, y: track.symbolScale)
                    .concatenating(CGAffineTransform(translationX: track.minusX, y: 70))
                context.stroke(minus.applying(minusT).applying(scale), with: .color(color), lineWidth: 15 * k)
            }
            if !letters.isEmpty {
                let text = Text(letters).font(.custom("MiSans-Bold", fixedSize: 16 * k)).tracking(22 * k).foregroundColor(color)
                context.draw(context.resolve(text), at: CGPoint(x: 20 * k, y: 177 * k), anchor: .bottomLeading)
            }
        }
    }
}

/// Permission scan: outer and white rings closing in, two inner arcs, the orange orbit dots,
/// the side arcs, satellites and core, and PERMISSION AUTHORIZED.
private struct ScanLayer: View {
    @Environment(\.palette) private var pal
    let state: BootState

    private func arc(_ cx: Double, _ cy: Double, _ r: Double, _ start: Double, _ sweep: Double) -> Path {
        var p = Path()
        let full = sweep >= .pi * 1.999
        let steps = max(8, Int(abs(sweep) / (.pi * 2) * 160))
        for i in 0...steps {
            let a = full ? start + .pi * 2 * Double(i) / Double(steps) : start + sweep * Double(i) / Double(steps)
            let point = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        if full { p.closeSubpath() }
        return p
    }

    private func dot(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    var body: some View {
        let s = state, scan = s.scan
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.opacity = s.ringOpacity
                if s.ringBlur > 0 { context.addFilter(.blur(radius: s.ringBlur)) }
                context.translateBy(x: 960, y: 540)
                context.scaleBy(x: s.ringScale, y: s.ringScale)
                context.translateBy(x: -960, y: -540)
                let ink = GraphicsContext.Shading.color(pal.ink)
                let light = GraphicsContext.Shading.color(pal.contour)
                let round = StrokeStyle(lineWidth: 2, lineCap: .round)
                context.stroke(arc(960, 540, scan.radius, scan.outerStart, scan.outerSweep), with: ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                context.stroke(arc(960, 540, scan.whiteRadius, scan.whiteStart, scan.whiteSweep), with: light, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                context.stroke(arc(960, 540, scan.innerRadius, scan.innerStart, scan.innerSweep), with: ink, style: round)
                context.stroke(arc(960, 540, scan.innerRadius, scan.innerStart + .pi, scan.innerSweep), with: ink, style: round)
                if s.scanOrbit.sideVisible {
                    for side in s.scanOrbit.sides {
                        context.stroke(arc(side.x, side.y, side.radius, side.start, side.sweep), with: ink, style: round)
                    }
                }
                for point in s.scanOrbit.satellites where point.radius > 0 {
                    context.fill(dot(point.x, point.y, point.radius), with: ink)
                }
                for i in 0..<2 {
                    let a = scan.orbit + Double(i) * .pi
                    context.fill(dot(960 + cos(a) * scan.orbitRadius, 540 + sin(a) * scan.orbitRadius, scan.dotRadius),
                                 with: .color(Color(red: 0.929, green: 0.51, blue: 0.106)))
                }
                if s.ornament { context.fill(dot(959.5, 539.5, s.scanOrbit.coreRadius), with: ink) }
                let capAngle = scan.outerStart + scan.outerSweep
                context.fill(dot(960 + cos(capAngle) * scan.radius, 540 + sin(capAngle) * scan.radius, scan.blackCap), with: ink)
                context.fill(dot(960 + cos(scan.whiteStart) * scan.whiteRadius, 540 + sin(scan.whiteStart) * scan.whiteRadius, scan.whiteCap), with: light)
            }
            .frame(width: 1920, height: 1080)

            LetteringText(keys: ["permission"], text: "PERMISSION AUTHORIZED", size: s.scanFont, tracking: s.scanTracking,
                          centeredIn: 1920, color: pal.ink)
                .offset(y: 540 - s.scanFont / 2 + 2)
                .opacity(s.permissionOpacity)
        }
    }
}

/// WELCOME TO / RHINE LAB.LLC. / INTERNAL DATABASE and the mark, on the black card that flashes
/// in, then shrinks and blurs away into the white (web `.welcome`, 480 × 340 at 720, 403).
private struct WelcomeLayer: View {
    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel
    let state: BootState

    var body: some View {
        let s = state
        let heading = model.dark ? pal.ink : Color(white: 1 - s.welcomeInk)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(pal.ink).frame(width: 470, height: 392).offset(x: 5, y: -59).opacity(s.welcomePanel)
            LetteringText(keys: ["welcome"], text: "WELCOME TO", size: 55, centeredIn: 480, color: heading).offset(y: 9)
            ZStack(alignment: .topLeading) {
                LetteringText(keys: ["company"], text: "RHINE LAB.LLC.", size: 48, tracking: -0.5, color: pal.ink)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                LetteringText(keys: ["company"], text: "RHINE LAB.LLC.", size: 48, tracking: -0.5, color: pal.paper)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .opacity(s.companyMask ? 0.06 : 1)
                    .background(pal.ink)
                    .mask(alignment: .leading) { Rectangle().frame(width: 410 * s.highlight) }
            }
            .frame(width: 410, height: 60, alignment: .topLeading)
            .offset(x: 35, y: 67)
            .opacity(s.companyVisible ? (s.companyMask ? 0.65 : 1) : 0)
            LetteringText(keys: ["database"], text: "INTERNAL DATABASE", size: 36, centeredIn: 480, color: pal.ink)
                .offset(y: 137.5)
                .opacity(s.databaseOpacity)
            BootLogo(track: BootLogoTrack(), letters: "RHINE·LAB", color: pal.ink)
                .frame(width: 203, height: 121)
                .offset(x: 138.5, y: 187)
                .opacity(s.welcomeLogo ? 1 : 0)
        }
        .frame(width: 480, height: 340, alignment: .topLeading)
        .scaleEffect(s.welcomeScale, anchor: UnitPoint(x: 0.5, y: 0.44))
        .opacity(s.welcomeOpacity)
        .blur(radius: s.exitBlur)
        .hueRotation(.degrees(115 * s.exit))
        .saturation(1 + 5 * s.exit)
    }
}
