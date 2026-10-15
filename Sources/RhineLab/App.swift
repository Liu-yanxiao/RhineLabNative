import SwiftUI
import AppKit

@main
struct RhineLabApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--search-flicker-check") {
            Task { @MainActor in let success = await MusicSearchFlickerDiagnostics.run(); exit(success ? 0 : 1) }
            RunLoop.main.run(); exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--flicker-check"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in let success = await MusicFlickerDiagnostics.run(output: output); exit(success ? 0 : 1) }
            RunLoop.main.run(); exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--search-check"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in let success = await MusicSearchDiagnostics.run(output: output); exit(success ? 0 : 1) }
            RunLoop.main.run(); exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--boot-check"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in let success = await MusicBootDiagnostics.run(output: output); exit(success ? 0 : 1) }
            RunLoop.main.run(); exit(1)
        }
        if CommandLine.arguments.contains("--lyrics-check") {
            Task { @MainActor in
                let service = MusicService()
                do {
                    let tracks = [MusicTrack(songID: "880374", title: "Speed of Light", artist: "塞壬唱片-MSR", album: "Speed of Light", duration: 245, artwork: nil, platform: "msr"),
                                  MusicTrack(songID: "66842", title: "十年", artist: "陈奕迅", album: "黑·白·灰", duration: 205, artwork: nil)]
                    for track in tracks {
                        let lyrics = try await service.lyrics(track)
                        guard lyrics.timed, lyrics.lines.count > 10 else { throw MusicFailure.message("Missing timed lyrics") }
                        print("PASS lyrics \(track.platform): \(lyrics.lines.count) timed lines; seek lookup \(lyrics.activeLine(at: 60) != nil)")
                    }
                    exit(0)
                } catch { print("FAIL lyrics: \(error.localizedDescription)"); exit(1) }
            }
            RunLoop.main.run(); exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--playlist-check"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in let success = await MusicSceneDiagnostics.run(output: output, builtins: true); exit(success ? 0 : 1) }
            RunLoop.main.run(); exit(1)
        }
        if CommandLine.arguments.contains("--render-check") {
            Task { @MainActor in let success = await MusicRenderDiagnostics.run(); exit(success ? 0 : 1) }
            RunLoop.main.run(); exit(1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--music-scene-check"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in
                let success = await MusicSceneDiagnostics.run(output: output)
                exit(success ? 0 : 1)
            }
            RunLoop.main.run()
            exit(1)
        }
        if CommandLine.arguments.contains("--music-check") {
            Task { @MainActor in
                let success = await MusicDiagnostics.run()
                exit(success ? 0 : 1)
            }
            RunLoop.main.run()
            exit(1)
        }
        if CommandLine.arguments.contains("--shot") || CommandLine.arguments.contains("--bench") || CommandLine.arguments.contains("--overlay-test") {
            ShotMode.run(CommandLine.arguments)
            exit(0)
        }
        Theme.registerFonts()
        NSApplication.shared.setActivationPolicy(.regular)
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup(Experience.music ? "RHINE MUSIC · MUSIC ARCHIVE" : "RHINE LAB · ANALYSIS OS") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 540)
                .onAppear {
                    // Set the running Dock tile from the bundled image explicitly; a replaced
                    // application can otherwise keep Launch Services' old cached icon.
                    if let url = Bundle.main.url(forResource: "RhineTerminal", withExtension: "icns"),
                       let icon = NSImage(contentsOf: url) {
                        NSApplication.shared.applicationIconImage = icon
                        NSApplication.shared.dockTile.display()
                    }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first {
                        window.titlebarAppearsTransparent = true
                        window.titleVisibility = .hidden
                        window.styleMask.insert(.fullSizeContentView)
                        window.backgroundColor = NSColor(model.dark ? Palette.activeDark.paper : Palette.light.paper)
                        window.contentAspectRatio = NSSize(width: 16, height: 9)
                    }
                }
                .onChange(of: model.dark) { _, dark in
                    NSApplication.shared.windows.first?.backgroundColor = NSColor(dark ? Palette.activeDark.paper : Palette.light.paper)
                }
        }
        .defaultSize(width: 1440, height: 810)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
