import AppKit
import SwiftUI
import simd

/// Exercises the same AppModel and renderer without driving or changing the user's window/library.
enum MusicSceneDiagnostics {
    @MainActor static func run(output: String, builtins: Bool = false) async -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            AppModel.headless = true
            Theme.registerFonts()
            let model = AppModel()
            model.reduced = false; model.dark = true
            let initialCount = model.musicLibrary.count
            model.musicPlayer.volume = 0; model.musicPlayer.shuffle = false
            var time = CACurrentMediaTime()
            func advance(_ seconds: Double) {
                for _ in 0..<Int(seconds * 60) {
                    time += 1.0 / 60
                    model.engine.tick(time: time, dt: 1.0 / 60)
                    if model.viewer.isOpen { model.viewer.tick(time: time, dt: 1.0 / 60) }
                }
            }
            func coverReady() async throws {
                for _ in 0..<120 {
                    if MusicArtwork.image(model.selected) != nil { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw MusicFailure.message("selected cover did not load")
            }
            func playingReady() async throws {
                for _ in 0..<450 {
                    if model.musicPlayer.status == .playing && model.musicPlayer.elapsed >= 1 { return }
                    if model.musicPlayer.status == .failed { throw MusicFailure.message(model.musicPlayer.error ?? "audio failed") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw MusicFailure.message("audio did not advance")
            }
            let songs = builtins ? model.sceneTracks : try await model.musicService.search("八千里路明月照")
            guard let track = (builtins ? songs.first : songs.first(where: { $0.songID == "3425454004" })) ?? songs.first else {
                throw MusicFailure.message("no diagnostic search results")
            }
            model.musicPlayer.play(track, in: songs, collectionID: builtins ? model.collection.id : nil)
            guard model.sceneTrack?.id == track.id, model.musicLibrary.count == initialCount else {
                throw MusicFailure.message("search playback did not select the song in the scene")
            }
            try await coverReady(); try await playingReady(); advance(8)
            try await snapshot(model, path: output + "/playing-main.png")
            model.open(); advance(4)
            try await Task.sleep(for: .seconds(1.6)); advance(2)
            guard model.freeSceneReady, model.engine.detailRequested else { throw MusicFailure.message("free detail did not open") }
            try await snapshot(model, path: output + "/playing-detail.png")
            if builtins {
                let lyrics = try await model.musicService.lyrics(track)
                guard lyrics.timed, lyrics.lines.count > 10 else { throw MusicFailure.message("missing timed lyrics") }
                model.musicDetailTab = 1
                model.musicPlayer.seek(45)
                try await Task.sleep(for: .milliseconds(450))
                guard abs(model.musicPlayer.elapsed - 45) < 3, lyrics.activeLine(at: model.musicPlayer.elapsed) != nil else {
                    throw MusicFailure.message("lyric time did not follow seek")
                }
                try await snapshot(model, path: output + "/lyrics-detail.png")
                model.musicDetailTab = 0
            }
            let previousID = model.sceneTrack!.id
            let camera = model.engine.makeFrame(aspect: 16.0 / 9.0).cameraPosition
            if builtins { model.navigateSong(1) } else { model.musicPlayer.next() }
            guard model.sceneTrack?.id == model.musicPlayer.current?.id, model.sceneTrack?.id != previousID else {
                throw MusicFailure.message("next did not retarget the scene")
            }
            try await coverReady(); try await playingReady(); advance(2)
            guard simd_distance(model.engine.makeFrame(aspect: 16.0 / 9.0).cameraPosition, camera) < 0.1 else { throw MusicFailure.message("next reset the free camera") }
            try await snapshot(model, path: output + "/next-detail.png")
            model.musicPlayer.pause()
            if builtins {
                let lane = model.lane
                model.navigateSong(1)
                guard model.lane == lane, model.musicPlayer.status == .paused else { throw MusicFailure.message("paused next changed playlist or started audio") }
            }
            advance(3)
            guard !model.engine.isAnimating else { throw MusicFailure.message("paused detail still animates: \(model.engine.activityReason)") }
            try await snapshot(model, path: output + "/paused-detail.png")
            model.back(); advance(8)
            try await snapshot(model, path: output + "/returned-main.png")
            model.musicPlayer.stop()
            print("PASS scene: search -> song/cover -> detail -> next -> pause -> return; no saved songs added")
            return true
        } catch {
            print("FAIL scene: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor static func snapshot(_ model: AppModel, path: String, bootTime: Double? = nil) async throws {
        let width = 2880, height = 1620
        let frame = model.viewer.isOpen ? model.viewer.makeFrame(aspect: 16.0 / 9.0) : model.engine.makeFrame(aspect: 16.0 / 9.0)
        guard let scene = ShotMode.capture(model.sceneView.renderer, frame, width: width, height: height) else {
            throw MusicFailure.message("no scene image")
        }
        if let bootTime { model.setBootTime(bootTime) }
        let stage = Stage().environmentObject(model).environment(\.palette, model.dark ? Palette.activeDark : .light).frame(width: 1920, height: 1080)
        let host = NSHostingView(rootView: stage)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = host
        defer { window.close() }
        host.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw MusicFailure.message("no interface bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let interface = bitmap.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MusicFailure.message("no interface image")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(scene, in: rect); context.draw(interface, in: rect)
        guard let image = context.makeImage() else { throw MusicFailure.message("no combined image") }
        ShotMode.write(image, to: path)
    }
}
