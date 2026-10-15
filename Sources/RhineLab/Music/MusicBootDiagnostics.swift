import AppKit

enum MusicBootDiagnostics {
    @MainActor static func run(output: String) async -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            AppModel.headless = true; Theme.registerFonts()
            let model = AppModel(bootPreview: true)
            for dark in [false, true] {
                model.dark = dark; model.replay()
                let theme = dark ? "dark" : "light"
                guard model.mode == .boot else { throw MusicFailure.message("boot was skipped") }
                model.advanceBoot(to: BootMotion.startTime + 3.3)
                guard model.mode == .boot else { throw MusicFailure.message("boot ended early") }
                for (name, time) in [("logo", 6.0), ("scan", 15.2), ("welcome", 20.5)] {
                    model.advanceBoot(to: time)
                    guard model.mode == .boot else { throw MusicFailure.message("missing boot chapter") }
                    try await MusicSceneDiagnostics.snapshot(model, path: output + "/\(theme)-\(name).png", bootTime: time)
                }
                model.advanceBoot(to: BootMotion.endTime)
                guard model.mode == .archive else { throw MusicFailure.message("boot did not enter library") }
                model.replay(); model.skipBoot()
                guard model.mode == .archive else { throw MusicFailure.message("skip failed") }
                let start = CACurrentMediaTime()
                for frame in 0..<480 { model.engine.tick(time: start + Double(frame) / 60, dt: 1.0 / 60) }
                model.present(.library)
                try await MusicSceneDiagnostics.snapshot(model, path: output + "/\(theme)-library.png")
                model.dismissModal(); model.present(.search)
                try await MusicSceneDiagnostics.snapshot(model, path: output + "/\(theme)-search.png")
                model.dismissModal(); model.present(.settings)
                try await MusicSceneDiagnostics.snapshot(model, path: output + "/\(theme)-settings.png")
                model.dismissModal()
                print("PASS \(theme): full boot, library entry, replay, skip, subpages")
            }
            return true
        } catch { print("FAIL boot: \(error.localizedDescription)"); return false }
    }
}
