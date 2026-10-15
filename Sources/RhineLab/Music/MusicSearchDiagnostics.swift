import AppKit

enum MusicSearchDiagnostics {
    @MainActor static func run(output: String) async -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            AppModel.headless = true; Theme.registerFonts()
            let model = AppModel(), query = "陈奕迅"
            let start = CACurrentMediaTime()
            let songs = try await model.musicService.search(query)
            let cold = CACurrentMediaTime() - start
            let cachedStart = CACurrentMediaTime()
            let cached = try await model.musicService.search(query)
            let warm = CACurrentMediaTime() - cachedStart
            guard songs.count > 15, cached == songs, warm < 0.15 else { throw MusicFailure.message("search cache or long-queue fixture failed") }
            print(String(format: "search: %d tracks, first %.3fs, cached %.4fs", songs.count, cold, warm))
            model.musicSearchQuery = query; model.musicSearchResultQuery = query; model.musicSearchResults = songs
            var time = CACurrentMediaTime()
            func advance() { for _ in 0..<480 { time += 1.0 / 60; model.engine.tick(time: time, dt: 1.0 / 60) } }
            for dark in [false, true] {
                model.dark = dark; model.present(.search); advance()
                try await MusicSceneDiagnostics.snapshot(model, path: output + (dark ? "/dark-results.png" : "/light-results.png"))
                model.dismissModal()
            }
            model.musicPlayer.selectPaused(songs.last!, in: songs, collectionID: nil); advance()
            try await MusicSceneDiagnostics.snapshot(model, path: output + "/long-queue.png")
            let window = MusicRail.window(count: model.columnFiles.count, selected: model.sceneNumber - 1)
            guard window.count <= 15, window.contains(model.sceneNumber - 1) else { throw MusicFailure.message("rail overflow") }
            model.musicPlayer.stop()
            print("PASS search: cached result reuse, light/dark results, bounded long queue")
            return true
        } catch { print("FAIL search: \(error.localizedDescription)"); return false }
    }
}
