import SwiftUI
import CoreText

enum Theme {
    static let ink = Color(red: 0.031, green: 0.039, blue: 0.031)        // #080a08
    static let paper = Color(red: 0.91, green: 0.898, blue: 0.882)       // #e8e5e1
    static let muted = Color(red: 0.467, green: 0.459, blue: 0.427)      // #77756d
    static let faint = Color(red: 0.522, green: 0.502, blue: 0.467)      // #858077
    static let accent = Color(red: 0.608, green: 0.447, blue: 0.278)     // #9b7247
    static let dark = Color(red: 0.145, green: 0.157, blue: 0.125)       // #252820

    /// MiSans, registered from the app bundle.
    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom(weight.rawValue, fixedSize: size)
    }
    enum Weight: String { case light = "MiSans-Light", regular = "MiSans-Regular", semibold = "MiSans-Demibold", bold = "MiSans-Bold" }

    static func registerFonts() {
        for name in ["MiSans-Light", "MiSans-Regular", "MiSans-Demibold", "MiSans-Bold"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

extension Color {
    /// sRGB colour from a 0xRRGGBB literal, so values can be copied straight from the web stylesheet.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

/// Interface colours for one theme. Values follow the web version's `theme-ui.ts` palette.
struct Palette {
    var ink, muted, body, index, line, paper, panel, panelEdge, field, accent, statusLight: Color
    var solid, onSolid, toast, onToast, flash, contour, bootInner, bootOuter, bootRim, shadow, switchOn: Color

    static let light = Palette(
        ink: Color(hex: 0x080a08), muted: Color(hex: 0x77756d), body: Color(hex: 0x5a584e), index: Color(hex: 0xa38e72),
        line: Color(hex: 0xaaa59a), paper: Color(hex: 0xeae5e1), panel: Color(hex: 0xedebe4), panelEdge: Color(hex: 0xf7f5ee),
        field: Color(hex: 0xe7e3d9), accent: Color(hex: 0x9b7247), statusLight: Color(hex: 0x777b60),
        solid: Color(hex: 0x252820), onSolid: Color(hex: 0xf0eee5), toast: Color(hex: 0x30362a), onToast: Color(hex: 0xf1efdf),
        flash: .white, contour: .white, bootInner: Color(hex: 0xe7e7e1), bootOuter: Color(hex: 0xe3e1dc), bootRim: Color(hex: 0xe4dfdb),
        shadow: Color(hex: 0x63513a, opacity: 0.125), switchOn: Color(hex: 0x565c46))

    static let dark = Palette(
        ink: Color(hex: 0xe0e3dc), muted: Color(hex: 0xa6b0b1), body: Color(hex: 0xa6b0b1), index: Color(hex: 0xc5a16b),
        line: Color(hex: 0x536166), paper: Color(hex: 0x11181b), panel: Color(hex: 0x202a2f), panelEdge: Color(hex: 0x536166),
        field: Color(hex: 0x2a363b), accent: Color(hex: 0xc5a16b), statusLight: Color(hex: 0xe0e3dc),
        solid: Color(hex: 0xe0e3dc), onSolid: Color(hex: 0x11181b), toast: Color(hex: 0x202a2f), onToast: Color(hex: 0xe0e3dc),
        flash: Color(hex: 0x11181b), contour: Color(hex: 0x536166), bootInner: Color(hex: 0x202a2f), bootOuter: Color(hex: 0x11181b), bootRim: Color(hex: 0x11181b),
        shadow: Color.black.opacity(0.2), switchOn: Color(hex: 0xc5a16b))
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Text that rolls upward when its value changes (titles, categories).
struct RollingText: View {
    let text: String
    var animated = true
    var body: some View {
        Text(text)
            .id(text)
            .transition(animated ? .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)) : .identity)
            .animation(animated ? .easeOut(duration: 0.46) : nil, value: text)
            .clipped()
    }
}
