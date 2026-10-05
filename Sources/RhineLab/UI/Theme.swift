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
