import XCTest
import AVFoundation
import MediaPlayer
@testable import RhineLab

private actor RhythmFileService: MusicProviding {
    let url: URL
    init(_ url: URL) { self.url = url }
    func search(_ keyword: String) async throws -> [RhineLab.MusicTrack] { [] }
    func resolve(_ track: RhineLab.MusicTrack, source: MusicSource) async throws -> URL { url }
}

@MainActor final class PlayerFeaturesTests: XCTestCase {
    func testRhythmDetectorRespondsToLowFrequencyOnsetsAndNotSilence() {
        var detector = MusicRhythmDetector()
        for _ in 0..<1024 { detector.sample(0) }
        let silent = detector.finish(time: 0)
        XCTAssertEqual(silent.level, 0); XCTAssertEqual(silent.beat, 0)
        for i in 0..<2048 { detector.sample(0.7 * sin(Float(i) * 2 * .pi * 80 / 48000)) }
        let kick = detector.finish(time: 0.2)
        XCTAssertGreaterThan(kick.beat, 0.1); XCTAssertGreaterThan(kick.bands[0], 0.1)
        var treble = MusicRhythmDetector()
        for i in 0..<2048 { treble.sample(0.7 * sin(Float(i) * 2 * .pi * 4000 / 48000)) }
        let high = treble.finish(time: 0.2)
        XCTAssertGreaterThan(high.bands[7], high.bands[0] * 3)
    }
    func testActualAVPlayerAudioTapReceivesSamplesWithoutChangingPlayback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rhine-audio-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rhythm.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000))
        buffer.frameLength = 192000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<192000 {
            let time = Float(i) / 48000
            channel[i] = time.truncatingRemainder(dividingBy: 0.5) < 0.12 ? 0.6 * sin(time * 2 * .pi * 80) : 0
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let player = RhineLab.MusicPlayer(service: RhythmFileService(url), persistent: false)
        player.volume = 0; player.shuffle = false; player.rhythm.enabled = true
        let song = RhineLab.MusicTrack(songID: "rhythm-fixture", title: "Rhythm", artist: "Test", album: "Fixture", duration: 4, artwork: nil)
        player.play(song, in: [song], collectionID: nil)
        defer { player.stop() }
        var received = false, beat: Float = 0
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            let frame = player.rhythm.snapshot()
            received = received || frame.received; beat = max(beat, frame.beat)
            if received && beat > 0.05 && player.elapsed > 0.3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(received, "actual AVPlayer PCM must reach the visualizer")
        XCTAssertGreaterThan(beat, 0.05)
        XCTAssertEqual(player.status, .playing)
        player.pause(); player.rhythm.enabled = false
        XCTAssertEqual(player.rhythm.snapshot().level, 0)
        XCTAssertFalse(player.rhythm.snapshot().received)
    }
    func testMediaCommandsUseTheExistingQueueAndPublishCorrectMetadata() {
        let player = RhineLab.MusicPlayer(service: RhythmFileService(URL(fileURLWithPath: "/nonexistent")), persistent: false)
        let songs = (1...3).map { RhineLab.MusicTrack(songID: "\($0)", title: "Track \($0)", artist: "Artist", album: "Album", duration: 180, artwork: nil) }
        player.shuffle = false
        XCTAssertEqual(MusicSystemControls.perform(.toggle, on: player), .noSuchContent)
        player.selectPaused(songs[1], in: songs, collectionID: nil)
        let metadata = MusicSystemControls.metadata(for: player)
        XCTAssertEqual(metadata?[MPMediaItemPropertyTitle] as? String, "Track 2")
        XCTAssertEqual(metadata?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(MusicSystemControls.perform(.next, on: player), .success)
        XCTAssertEqual(player.current?.id, songs[2].id)
        _ = MusicSystemControls.perform(.pause, on: player)
        XCTAssertEqual(player.status, .paused)
        _ = MusicSystemControls.perform(.previous, on: player)
        XCTAssertEqual(player.current?.id, songs[1].id)
        _ = MusicSystemControls.perform(.stop, on: player)
        XCTAssertNil(MusicSystemControls.metadata(for: player))
        XCTAssertEqual(player.status, .idle)
    }
    func testWindowTransparencyCanReturnToAnOpaqueReadableWindow() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 540), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        WindowAppearance.apply(to: window, opacity: 0.7, glass: true, dark: false)
        XCTAssertEqual(window.alphaValue, 0.7, accuracy: 0.001)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        WindowAppearance.apply(to: window, opacity: 1, glass: false, dark: false)
        XCTAssertEqual(window.alphaValue, 1); XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(WindowAppearance.opacity(.nan), 1)
        XCTAssertGreaterThan(WindowAppearance.opacity(0), 0.5, "the settings must remain recoverable")
    }
}
