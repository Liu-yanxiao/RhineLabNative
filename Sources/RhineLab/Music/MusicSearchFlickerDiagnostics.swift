import AppKit
import Metal

enum MusicSearchFlickerDiagnostics {
    @MainActor static func run() async -> Bool {
        AppModel.headless = true
        let model = AppModel()
        let live = CommandLine.arguments.contains("--search-flicker-live")
        var liveSongs: [MusicTrack] = []
        if live {
            do { liveSongs = try await model.musicService.search("陈奕迅") }
            catch { print("FAIL online search: \(error)"); return false }
            guard liveSongs.count >= 24 else { return false }
        }
        var passed = true
        for cycle in 0..<(live ? 2 : 6) {
        model.dark = cycle % 2 == 1
        // Deterministic 30-result search queue, installed through the real playback/presentation path.
        let songs = live ? liveSongs : (0..<30).map { MusicTrack(songID: "fixture-\(cycle)-\($0)", title: "Cover \($0)", artist: "Fixture", album: "Search", duration: 180, artwork: nil) }
        model.present(.search)
        model.musicSearchResults = songs
        model.musicPlayer.selectPaused(songs[12], in: songs, collectionID: nil)
        model.dismissModal()
        if live { try? await Task.sleep(for: .seconds(20)) }
        else { model.sceneView.clearMusicArtwork() }
        var time = CACurrentMediaTime()
        for _ in 0..<1200 { time += 1.0/60; model.engine.tick(time: time, dt: 1.0/60) }
        let initial = model.engine.makeFrame(aspect: 16.0/9.0)
        let selected = initial.cards[0].labelIndex
        let available = Set(initial.arrayLabels).subtracting([selected]).sorted()
        guard available.count >= 24 else { print("FAIL insufficient visible fixture labels: \(available.count)"); return false }
        for index in available.prefix(live ? 0 : 24) {
            let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor(srgbRed: CGFloat(index % 3) / 3 + 0.3, green: 0.7, blue: 0.4, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            MusicArtwork.store(ctx.makeImage()!, index: index)
        }
        let renderer = model.sceneView.renderer
        renderer.clearLabels()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 960, height: 540, mipmapped: false)
        desc.storageMode = .shared; desc.usage = [.renderTarget, .shaderRead]
        guard let target = renderer.device.makeTexture(descriptor: desc) else { return false }
        var missingFrames = 0, worstMissing = 0, changedFrames = 0
        var pixels = [UInt8](repeating: 0, count: 960 * 540 * 4), previousPixels: [UInt8] = []
        for i in 0..<360 {
            let frame = model.engine.makeFrame(aspect: 16.0/9.0)
            let required = Set(frame.arrayPrints.map(\.labelIndex) + frame.cards.filter { $0.quality > 0.001 }.map(\.labelIndex))
            if i == 0 { print("Search scene needs \(required.count) simultaneous labels"); fflush(stdout) }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in renderer.render(frame, to: target) { c.resume() } }
            if i >= 120 {
                target.getBytes(&pixels, bytesPerRow: 960 * 4, from: MTLRegionMake2D(0, 0, 960, 540), mipmapLevel: 0)
                if !previousPixels.isEmpty && pixels != previousPixels { changedFrames += 1 }
                previousPixels = pixels
                let missing = required.subtracting(renderer.readyLabelIndices).count
                if missing > 0 { missingFrames += 1; worstMissing = max(worstMissing, missing) }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        print("\(missingFrames == 0 ? "PASS" : "FAIL") after search: \(missingFrames)/240 steady frames lost covers; peak \(worstMissing)")
        print("cycle \(cycle): \(changedFrames) unexpected pixel changes in frozen scene; \(renderer.readyLabelIndices.count) resident covers")
        passed = passed && missingFrames == 0 && changedFrames == 0 && renderer.readyLabelIndices.count <= 25
        }
        return passed
    }
}
