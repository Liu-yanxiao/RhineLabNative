import SwiftUI

// Small interface pieces shared by the HUD and the dialogs. Geometry follows the web version.

/// Magnifier drawn from fixed proportions (ring upper right, handle lower left) rather than a
/// system symbol, so it matches the original at any size. Uses the current foreground colour.
struct MagnifierGlyph: View {
    var size: CGFloat = 23

    var body: some View {
        Canvas { context, area in
            let w = area.width, h = area.height
            let ring = CGRect(x: w * 0.30, y: h * 0.08, width: w * 0.60, height: h * 0.60).insetBy(dx: 1, dy: 1)
            context.stroke(Path(ellipseIn: ring), with: .foreground, lineWidth: 2)
            let reach = w * 0.42 * 0.7071
            var handle = Path()
            handle.move(to: CGPoint(x: w * 0.09, y: h * 0.82))
            handle.addLine(to: CGPoint(x: w * 0.09 + reach, y: h * 0.82 - reach))
            context.stroke(handle, with: .foreground, lineWidth: 2)
        }
        .frame(width: size, height: size)
    }
}

/// Two crossing 2 pt strokes, as used by the dialog close button.
struct CloseGlyph: View {
    var body: some View {
        Canvas { context, area in
            let c = CGPoint(x: area.width / 2, y: area.height / 2)
            let d: CGFloat = 4.95   // half of a 14 pt stroke at 45°
            var path = Path()
            path.move(to: CGPoint(x: c.x - d, y: c.y - d)); path.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
            path.move(to: CGPoint(x: c.x - d, y: c.y + d)); path.addLine(to: CGPoint(x: c.x + d, y: c.y - d))
            context.stroke(path, with: .foreground, lineWidth: 2)
        }
        .frame(width: 16, height: 34)
    }
}

/// Outlined key label ("/", "ESC").
struct KeyCap: View {
    @Environment(\.palette) private var pal
    let label: String
    var width: CGFloat? = nil
    var height: CGFloat = 21
    var size: CGFloat = 11

    var body: some View {
        Text(label).font(Theme.font(size))
            .frame(width: width, height: height)
            .frame(minWidth: 19)
            .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
            .opacity(0.6)
    }
}

/// 46 × 46 arrow button that fills with warm sand on hover.
struct ArrowButton: View {
    @Environment(\.palette) private var pal
    let glyph: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(glyph).font(Theme.font(size))
                .frame(width: 46, height: 46)
                .background(hovering ? pal.field : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.3), value: hovering)
    }
}

/// Square on/off switch (50 × 24) in the dialog's olive tone.
struct SquareSwitch: View {
    @Environment(\.palette) private var pal
    let isOn: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(isOn ? pal.switchOn : pal.field)
            Rectangle().fill(Color(hex: 0xf5f2e9)).frame(width: 16, height: 16).offset(x: isOn ? 30 : 4)
        }
        .frame(width: 50, height: 24)
        .animation(.easeOut(duration: 0.3), value: isOn)
    }
}
