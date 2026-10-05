import SwiftUI
import AppKit

@main
struct RhineLabApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--shot") || CommandLine.arguments.contains("--bench") || CommandLine.arguments.contains("--overlay-test") {
            ShotMode.run(CommandLine.arguments)
            exit(0)
        }
        Theme.registerFonts()
        NSApplication.shared.setActivationPolicy(.regular)
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("RHINE LAB · ANALYSIS OS") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 540)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first {
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .hidden
                        window.styleMask.insert(.fullSizeContentView)
                        window.backgroundColor = model.dark ? NSColor(srgbRed: 0.067, green: 0.094, blue: 0.106, alpha: 1)
                                                           : NSColor(srgbRed: 0.918, green: 0.898, blue: 0.882, alpha: 1)
                        window.contentAspectRatio = NSSize(width: 16, height: 9)
                    }
                }
                .onChange(of: model.dark) { _, dark in
                    NSApplication.shared.windows.first?.backgroundColor = dark
                        ? NSColor(srgbRed: 0.067, green: 0.094, blue: 0.106, alpha: 1)
                        : NSColor(srgbRed: 0.918, green: 0.898, blue: 0.882, alpha: 1)
                }
        }
        .defaultSize(width: 1440, height: 810)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
