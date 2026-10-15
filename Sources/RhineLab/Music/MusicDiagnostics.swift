import Foundation

/// Explicit live smoke check; no preferences written and playback muted.
enum MusicDiagnostics {
    @MainActor
    static func run() async -> Bool {
        let service = MusicService()
        let player = MusicPlayer(service: service, persistent: false)
        player.volume = 0; player.shuffle = false
        func wait(_ condition: () -> Bool, seconds: Double = 25) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                if player.status == .failed { return false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        do {
            let tracks = Array(try await service.search("牵丝戏").prefix(3))
            guard tracks.count == 3 else { print("FAIL search: expected three samples"); return false }
            let sources = CommandLine.arguments.contains("--hyw-only") ? [MusicSource.hyw] : MusicSource.allCases
            for source in sources {
                player.source = source
                player.play(tracks[0], in: tracks, collectionID: "gufeng")
                guard await wait({ player.status == .playing && player.elapsed > 1 }), player.activeSource == source else {
                    print("FAIL \(source.label) start: \(player.error ?? player.status.rawValue)"); player.stop(); return false
                }
                player.pause()
                let paused = player.elapsed
                try? await Task.sleep(for: .milliseconds(650))
                guard player.status == .paused, abs(player.elapsed - paused) < 0.4 else { print("FAIL pause"); return false }
                player.toggle()
                guard await wait({ player.status == .playing && player.elapsed > paused + 0.4 }, seconds: 10) else { print("FAIL resume"); return false }
                player.seek(12)
                guard await wait({ player.elapsed >= 12 && player.elapsed < 17 }, seconds: 10) else { print("FAIL seek"); return false }
                player.next()
                guard await wait({ player.status == .playing && player.elapsed > 1 }), player.current?.id == tracks[1].id else {
                    print("FAIL next: \(player.error ?? player.status.rawValue)"); return false
                }
                print("PASS \(source.label): native playback advances; pause/resume/seek/next work (muted)")
                player.stop()
            }
            return true
        } catch {
            print("FAIL \(error.localizedDescription)"); player.stop(); return false
        }
    }
}
