import SwiftUI

/// Short, interruptible feedback using the film's fine rules and square registration marks.
struct RhineButtonStyle: ButtonStyle {
    var active = true
    func makeBody(configuration: Configuration) -> some View {
        Response(label: configuration.label, pressed: configuration.isPressed, active: active)
    }
    private struct Response<Label: View>: View {
        let label: Label
        let pressed: Bool
        let active: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var systemReduced
        @Environment(\.palette) private var pal
        @EnvironmentObject private var model: AppModel
        @State private var hovered = false
        var body: some View {
            let lit = active && enabled && (hovered || pressed)
            label
                .background(pal.ink.opacity(lit ? (pressed ? 0.075 : 0.025) : 0))
                .overlay(alignment: .bottomLeading) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(pal.ink.opacity(pressed ? 0.85 : 0.4))
                                .frame(width: lit ? geo.size.width : 0, height: 1)
                            Rectangle().fill(pal.ink).frame(width: 3, height: 3)
                                .offset(x: lit ? max(0, geo.size.width - 3) : 0).opacity(lit ? 0.8 : 0)
                        }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }.allowsHitTesting(false)
                }
                .overlay {
                    RhineCorners(length: 5).trim(from: 0, to: lit ? 1 : 0)
                        .stroke(pal.ink.opacity(pressed ? 0.75 : 0.3), lineWidth: 0.7)
                        .padding(pressed ? 0 : -3).allowsHitTesting(false)
                }
                .opacity(enabled ? 1 : 0.4)
                // Keep labels fixed: the film confirms focus with registration marks and a sweep.
                .animation(model.reduced || systemReduced ? nil : .easeOut(duration: pressed ? 0.08 : 0.2), value: pressed)
                .animation(model.reduced || systemReduced ? nil : .easeOut(duration: 0.18), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

struct RhineClickFeedback: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.palette) private var pal
    @State private var end = false
    var body: some View {
        ZStack {
            Circle().trim(from: 0.04, to: 0.36).stroke(pal.ink.opacity(0.4), lineWidth: 0.7)
                .rotationEffect(.degrees(end ? -40 : 35))
            Circle().trim(from: 0.54, to: 0.86).stroke(pal.ink.opacity(0.4), lineWidth: 0.7)
                .rotationEffect(.degrees(end ? -40 : 35))
            RhineCorners(length: 5).stroke(pal.ink.opacity(0.6), lineWidth: 0.8)
            Rectangle().fill(pal.ink).frame(width: 3, height: 3)
        }.frame(width: 28, height: 28)
            .scaleEffect(end && !model.reduced && !systemReduced ? 0.45 : 1)
            .opacity(end ? 0 : 0.85)
            .onAppear { withAnimation(.easeOut(duration: model.reduced || systemReduced ? 0.16 : 0.42)) { end = true } }
            .accessibilityHidden(true)
    }
}

struct RhineCorners: Shape {
    var length: CGFloat = 11
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                              (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x + length * dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + length * dy))
        }
        return path
    }
}

private struct RhineReveal: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    var order: Int
    @State private var appeared = false
    func body(content: Content) -> some View {
        let ready = appeared || AppModel.headless || model.reduced || systemReduced
        content.opacity(ready ? 1 : 0).offset(y: ready ? 0 : 9)
            .animation(model.reduced || systemReduced ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.48).delay(Double(min(order, 6)) * 0.045), value: appeared)
            .onAppear { appeared = true }
    }
}

extension View {
    func rhineReveal(_ order: Int = 0) -> some View { modifier(RhineReveal(order: order)) }
}

/// A translucent reading field that dissolves into the scene; only small registration corners remain.
struct RhineReadingField: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var pal
    var body: some View {
        ZStack {
            LinearGradient(colors: [pal.paper.opacity(0.08), pal.paper.opacity(model.dark ? 0.72 : 0.75), pal.paper.opacity(0.82)],
                           startPoint: .leading, endPoint: .trailing)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            RhineCorners(length: 8).stroke(pal.line.opacity(0.45), lineWidth: 0.8)
        }.allowsHitTesting(false)
    }
}

struct RhineMusicBrand: View {
    @Environment(\.palette) private var pal
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            LetteringText(keys: ["brand"], text: "RHINE LAB", size: 48, tracking: 1, color: pal.ink).frame(width: 265, height: 47)
            Text("SYNTHESIZE INFORMATION").font(Theme.font(14)).tracking(0.6)
            HStack(spacing: 12) { Text("MUSIC").font(Theme.font(22, .light)); Text("ARCHIVE").font(Theme.font(22, .semibold)) }
        }.foregroundStyle(pal.ink).accessibilityElement(children: .combine)
    }
}

struct RhineScanProgress: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var pal
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.reduced || systemReduced)) { timeline in
            let angle = model.reduced || systemReduced ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) * 180
            ZStack {
                Circle().trim(from: 0.05, to: 0.66).stroke(pal.ink.opacity(0.65), lineWidth: 0.8).rotationEffect(.degrees(angle))
                Circle().trim(from: 0.1, to: 0.43).stroke(pal.line, lineWidth: 0.8).padding(4).rotationEffect(.degrees(-angle))
                Rectangle().fill(pal.accent).frame(width: 2, height: 2)
            }
        }.frame(width: 18, height: 18).accessibilityLabel("正在搜索")
    }
}
