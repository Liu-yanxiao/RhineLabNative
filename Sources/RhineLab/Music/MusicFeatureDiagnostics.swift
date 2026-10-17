import Foundation
import QuartzCore

enum MusicFeatureDiagnostics {
    @MainActor static func run(output: String) async -> Bool {
        AppModel.headless = true
        Theme.registerFonts()
        let model = AppModel()
        model.reduced = false; model.dark = false
        model.rhythmEnabled = true; model.musicPlayer.volume = 0; model.musicPlayer.shuffle = false
        defer { model.musicPlayer.stop() }
        model.playSelection(); model.open()
        var received = false, beat: Float = 0, level: Float = 0
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let frame = model.musicPlayer.rhythm.snapshot()
            received = received || frame.received; beat = max(beat, frame.beat); level = max(level, frame.level)
            if received && model.musicPlayer.elapsed > 2 { break }
            if model.musicPlayer.status == .failed { print("FAIL online playback: \(model.musicPlayer.error ?? "unknown")"); return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        print("Online audio: \(model.musicPlayer.status.rawValue), samples \(received), peak level \(level), onset \(beat)")
        guard received && level > 0.001 else { print("FAIL online stream did not provide analyzable audio"); return false }
        do {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            var time = CACurrentMediaTime()
            for _ in 0..<720 { time += 1.0 / 60; model.engine.tick(time: time, dt: 1.0 / 60) }
            try await MusicSceneDiagnostics.snapshot(model, path: output + "/detail-rhythm.png")
            model.present(.settings)
            try await MusicSceneDiagnostics.snapshot(model, path: output + "/settings.png")
            print("PASS online audio rhythm and feature interface snapshots")
            return true
        } catch { print("FAIL feature snapshots: \(error)"); return false }
    }
}
