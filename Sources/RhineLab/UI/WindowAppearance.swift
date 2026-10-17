import SwiftUI
import AppKit

enum WindowAppearance {
    static func opacity(_ value: Double) -> Double { value.isFinite ? min(1, max(0.55, value)) : 1 }
    @MainActor static func apply(to window: NSWindow, opacity: Double, glass: Bool, dark: Bool) {
        window.alphaValue = Self.opacity(opacity)
        window.isOpaque = !glass
        window.backgroundColor = glass ? .clear : NSColor(dark ? Palette.activeDark.paper : Palette.light.paper)
        window.hasShadow = true
    }
}

/// Native window glass; the scene and readable interface remain separate layers above it.
struct RhineWindowGlass: NSViewRepresentable {
    var dark: Bool
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .clear; view.cornerRadius = 22; view.contentView = NSView()
            return view
        }
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = NSColor(dark ? Palette.activeDark.paper : Palette.light.paper).withAlphaComponent(0.08)
        }
    }
}
