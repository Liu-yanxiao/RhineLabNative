import XCTest
import ImageIO
import simd
import AppKit
@testable import RhineLab

private actor FixtureService: MusicProviding {
    func search(_ keyword: String) async throws -> [MusicTrack] { [] }
    func resolve(_ track: MusicTrack, source: MusicSource) async throws -> URL {
        try? await Task.sleep(for: .milliseconds(250))
        return URL(fileURLWithPath: "/nonexistent-cancelled-sample.mp3")
    }
}

private actor FixtureLyricsService: MusicLyricsProviding {
    func lyrics(_ track: MusicTrack) async throws -> MusicLyrics {
        try? await Task.sleep(for: .milliseconds(track.songID == "1" ? 100 : 5))
        return MusicLyrics("[00:01.00]" + track.title)
    }
}

@MainActor
final class MusicTests: XCTestCase {
    func testLateLyricsResponseCannotReplaceTheNewSong() async throws {
        let state = MusicLyricsState(), service = FixtureLyricsService()
        let first = Task { await state.load(songs[0], service: service) }
        try await Task.sleep(for: .milliseconds(15))
        await state.load(songs[1], service: service)
        await first.value
        XCTAssertEqual(state.document?.lines.first?.text, "Two")
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.error)
    }

    func testColumnScrollCommitsOnceAndIgnoresInertia() {
        var scroll = MusicLibraryScroll()
        func input(_ dx: CGFloat, _ phase: NSEvent.Phase, _ time: Double, momentum: NSEvent.Phase = []) -> MusicLibraryScroll.Action {
            scroll.consume(dx: dx, dy: 2, phase: phase, momentum: momentum, precise: true, time: time)
        }
        XCTAssertEqual(input(40, .began, 1), .none)
        XCTAssertEqual(input(35, .changed, 1.02), .none)
        XCTAssertEqual(input(40, .changed, 1.04), .column(1))
        XCTAssertEqual(input(300, .changed, 1.06), .none)
        XCTAssertEqual(input(0, .ended, 1.08), .none)
        XCTAssertEqual(input(300, [], 1.10, momentum: .began), .none)
        XCTAssertEqual(input(-300, [], 1.12, momentum: .changed), .none)
        XCTAssertEqual(input(-120, .began, 1.3), .column(-1))
        XCTAssertEqual(input(-150, .changed, 1.32), .none)
    }

    func testVerticalScrollDoesNotSwitchColumnsWhenDirectionDrifts() {
        var scroll = MusicLibraryScroll()
        XCTAssertEqual(scroll.consume(dx: 2, dy: 20, phase: .began, momentum: [], precise: true, time: 1), .none)
        XCTAssertEqual(scroll.consume(dx: 12, dy: 25, phase: .changed, momentum: [], precise: true, time: 1.02), .song(1))
        XCTAssertEqual(scroll.consume(dx: 150, dy: 0, phase: .changed, momentum: [], precise: true, time: 1.04), .none)
        XCTAssertEqual(scroll.consume(dx: 160, dy: 45, phase: [], momentum: .changed, precise: true, time: 1.06), .song(1))
        XCTAssertEqual(scroll.consume(dx: 120, dy: 2, phase: .began, momentum: [], precise: true, time: 2), .column(1))
    }

    func testDiagonalBrowseSeparatesSongsFromColumns() {
        var scroll = MusicLibraryScroll()
        // Screen-space ↙↗ switches columns; ↖↘ browses the current playlist.
        XCTAssertEqual(scroll.consume(dx: 90, dy: 90, phase: .began, momentum: [], precise: true, time: 1), .column(1))
        XCTAssertEqual(scroll.consume(dx: -90, dy: -90, phase: .began, momentum: [], precise: true, time: 2), .column(-1))
        XCTAssertEqual(scroll.consume(dx: 60, dy: -60, phase: .began, momentum: [], precise: true, time: 3), .song(1))
        XCTAssertEqual(scroll.consume(dx: -60, dy: 60, phase: .began, momentum: [], precise: true, time: 4), .song(-1))
    }

    func testFullBootIncludesRequestLogoScanAndWelcome() {
        XCTAssertGreaterThan(BootMotion.endTime - BootMotion.startTime, 20)
        XCTAssertGreaterThan(BootMotion.state(appTime: 2.5).accessOpacity, 0)
        XCTAssertGreaterThan(BootMotion.state(appTime: 6).logoOpacity, 0)
        XCTAssertTrue(BootMotion.state(appTime: 15).scanVisible)
        XCTAssertTrue(BootMotion.state(appTime: 19).welcomeVisible)
        XCTAssertEqual(BootMotion.state(appTime: BootMotion.endTime).backgroundOpacity, 0)
    }

    func testCoverReturnsToRestAfterInteractionStops() {
        let engine = ArchiveEngine(); engine.reduced = false; engine.targetReveal = 1
        engine.select(0, time: 0)
        var time = 0.0
        func advance(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { time += 1.0 / 60; engine.tick(time: time, dt: 1.0 / 60) } }
        advance(6); engine.setDetail(true, time: time); advance(6)
        engine.inspect(dx: 140, dy: 60); advance(0.2)
        XCTAssertGreaterThan(abs(engine.makeFrame(aspect: 16.0 / 9.0).cards[0].yaw), 0.15)
        advance(9)
        let rest = engine.makeFrame(aspect: 16.0 / 9.0).cards[0]
        XCTAssertLessThan(abs(rest.yaw), 0.005)
        XCTAssertLessThan(abs(rest.tilt), 0.005)
        XCTAssertFalse(engine.isAnimating)
    }

    func testDetailSwipeRequiresDeliberateTravelAndCommitsOnlyOnce() {
        var scroll = MusicDetailScroll()
        XCTAssertNil(scroll.consume(dx: 0, dy: 40, phase: .began, momentum: [], precise: true, time: 1))
        XCTAssertNil(scroll.consume(dx: 0, dy: 30, phase: .changed, momentum: [], precise: true, time: 1.02))
        XCTAssertEqual(scroll.consume(dx: 0, dy: 45, phase: .changed, momentum: [], precise: true, time: 1.04), 1)
        XCTAssertNil(scroll.consume(dx: 0, dy: 300, phase: .changed, momentum: [], precise: true, time: 1.06))
        XCTAssertNil(scroll.consume(dx: 0, dy: 300, phase: [], momentum: .began, precise: true, time: 1.08))
        XCTAssertEqual(scroll.consume(dx: -120, dy: 2, phase: .began, momentum: [], precise: true, time: 2), -1)
    }

    func testLyricsTimestampsTranslationsOffsetsAndSeekLookup() {
        let document = MusicLyrics("[ar:Fixture]\n[offset:-250]\n[00:04.50][00:12.50]Repeat\n[00:01.00]Start\n[00:04.50]Second line", translation: "[00:00.75]开头\n[00:04.25]重复")
        XCTAssertEqual(document.lines.count, 3)
        XCTAssertEqual(document.lines[0].translation, "开头")
        XCTAssertEqual(document.lines[1].translation, "重复")
        XCTAssertNil(document.activeLine(at: 0.5))
        XCTAssertEqual(document.activeLine(at: 4.25), 1)
        XCTAssertEqual(document.activeLine(at: 13), 2)
        XCTAssertEqual(document.activeLine(at: 1), 0)
        XCTAssertFalse(MusicLyrics("[ar:Fixture]\nA plain line").timed)
        XCTAssertEqual(MusicLyrics("[ar:Fixture]\nA plain line").lines.first?.text, "A plain line")
        XCTAssertTrue(MusicLyrics("").lines.isEmpty)
    }

    private let songs = [
        MusicTrack(songID: "1", title: "One", artist: "Test", album: "Fixture", duration: 60, artwork: nil),
        MusicTrack(songID: "2", title: "Two", artist: "Test", album: "Fixture", duration: 90, artwork: nil),
    ]
    func testPauseCancelsPendingPlaybackWithoutLateRestart() async throws {
        let player = MusicPlayer(service: FixtureService(), persistent: false)
        player.play(songs[0], in: songs, collectionID: "custom"); player.pause()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(player.status, .paused); XCTAssertNil(player.activeSource); XCTAssertNil(player.error)
    }
    func testRapidNextAndStopInvalidateOldResolution() async throws {
        let player = MusicPlayer(service: FixtureService(), persistent: false)
        player.shuffle = false; player.play(songs[0], in: songs, collectionID: "custom"); player.next()
        XCTAssertEqual(player.current?.id, songs[1].id)
        player.stop(); try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(player.status, .idle); XCTAssertNil(player.current); XCTAssertNil(player.activeSource); XCTAssertNil(player.error)
    }
    func testCustomPlaylistsAndLikesRoundTripWithoutDuplicates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = MusicLibrary(storageURL: url, migrate: false)
        let item = try XCTUnwrap(library.create("My list"))
        library.add(songs[0], to: item); library.add(songs[0], to: item); library.toggleLike(songs[1]); library.rename(item, to: "Renamed")
        let loaded = MusicLibrary(storageURL: url, migrate: false)
        let restored = try XCTUnwrap(loaded.collections.first { $0.id == item.id })
        XCTAssertEqual(restored.title, "Renamed"); XCTAssertEqual(loaded.tracks(restored), [songs[0]]); XCTAssertEqual(loaded.liked, [songs[1].id])
        loaded.toggleLike(songs[1]); XCTAssertTrue(loaded.liked.isEmpty)
    }
    func testOldGeneratedCachesAreNotImportedIntoUserLibrary() throws {
        struct Legacy: Encodable { let playlists: [String: [MusicTrack]] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try JSONEncoder().encode(Legacy(playlists: ["favorites": [songs[0]], "custom": [songs[1]], "gufeng": songs]))
        try original.write(to: url)
        let library = MusicLibrary(storageURL: url, migrate: false)
        XCTAssertEqual(library.collections.map(\.id), ["favorites", "custom"])
        XCTAssertEqual(library.count, 2); XCTAssertNil(library.playlists["gufeng"])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testNewLibraryStartsEmptyAndDynamicArchiveMappingStaysValid() {
        let library = MusicLibrary(storageURL: nil, migrate: false)
        XCTAssertEqual(library.count, 0)
        for i in 0..<15 { _ = library.create("List \(i)") }
        for index in library.collections.indices {
            let p = Archive.location(of: index)
            XCTAssertEqual(Archive.file(at: Cell(lane: p.lane, row: p.row)), index)
        }
    }
    func testSearchPlaybackDrivesSceneAndNextFollowsWithoutSavingSongs() {
        let library = MusicLibrary(storageURL: nil, migrate: false)
        let player = MusicPlayer(service: FixtureService(), persistent: false)
        let presentation = MusicPresentation(library: library, player: player)
        defer { player.stop(); MusicCatalog.presentQueue([]) }
        player.shuffle = false
        var updates: [(Int, Bool)] = []
        presentation.onSelection = { updates.append(($0, $1)) }
        player.play(songs[0], in: songs, collectionID: nil)
        XCTAssertEqual(MusicCatalog.items[presentation.selectedIndex].track, songs[0])
        XCTAssertEqual(Archive.records[presentation.selectedIndex].title, songs[0].title)
        XCTAssertEqual(MusicCatalog.queue, songs)
        XCTAssertTrue(updates.last!.1)
        player.next()
        XCTAssertEqual(MusicCatalog.items[presentation.selectedIndex].track, songs[1])
        XCTAssertFalse(updates.last!.1)
        presentation.select(0)
        presentation.locatePlaying()
        XCTAssertEqual(MusicCatalog.items[presentation.selectedIndex].track, songs[1])
        player.pause()
        XCTAssertEqual(MusicCatalog.items[presentation.selectedIndex].track, songs[1])
        XCTAssertEqual(library.count, 0)
        XCTAssertEqual(library.collections.count, 2)
    }

    func testPlaybackStopsMotionAndDetailSwitchKeepsFreeCamera() {
        let viewer = ViewerEngine(); viewer.musicDetail = true; viewer.open(labelIndex: 2)
        func settle(_ from: Double = 0) { for i in 0..<240 { viewer.tick(time: from + Double(i) / 60, dt: 1.0 / 60) } }
        viewer.orbit(dx: 140, dy: 120, viewHeight: 720); settle()
        let pose = viewer.cameraPosition
        viewer.setMusicPlaying(true); settle(4)
        XCTAssertTrue(viewer.isAnimating)
        XCTAssertTrue(viewer.isMusicPlaybackOnly)
        viewer.selectLabel(3)
        settle(8)
        XCTAssertEqual(viewer.labelIndex, 3)
        XCTAssertLessThan(simd_distance(viewer.cameraPosition, pose), 0.001)
        viewer.orbit(dx: 40, dy: 0, viewHeight: 720)
        XCTAssertFalse(viewer.isMusicPlaybackOnly)
        settle(12)
        XCTAssertTrue(viewer.isMusicPlaybackOnly)
        viewer.setMusicPlaying(false); settle(16)
        XCTAssertFalse(viewer.isAnimating)
    }

    func testMusicRenderBudgetAndThumbnailBounds() throws {
        XCTAssertGreaterThanOrEqual(RenderQuality.pixelBudget, 4_665_600)
        XCTAssertTrue(RenderQuality.musicBalanced.antialias)
        let source = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = source.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        let thumbnail = try XCTUnwrap(MusicArtwork.thumbnail(data as Data))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 512)
        XCTAssertEqual(thumbnail.width * 3, thumbnail.height * 4)
    }

    func testPlaylistColumnsContainOnlyTheirSongsAndLoopIndependently() {
        let library = MusicLibrary(storageURL: nil, migrate: false)
        defer { MusicCatalog.presentQueue([]) }
        let first = library.collections[0], second = library.collections[1]
        library.add(songs[0], to: first); library.add(songs[1], to: first)
        library.add(songs[0], to: second)
        XCTAssertEqual(Archive.columns, library.collections.map(\.id))
        XCTAssertEqual(Archive.columnFiles(0).count, 2)
        XCTAssertEqual(Archive.columnFiles(1).count, 1)
        for lane in 0..<2 {
            let files = Archive.columnFiles(lane)
            for index in files {
                XCTAssertEqual(MusicCatalog.items[index].collection?.id, library.collections[lane].id)
                let row = Archive.location(of: index).row
                XCTAssertEqual(Archive.file(at: Cell(lane: lane, row: row + files.count * 7)), index)
            }
        }
        XCTAssertEqual(Set(MusicCatalog.items.map(\.id)).count, MusicCatalog.items.count)
    }

    func testMusicCoverHasBoundedInteractionAndResets() {
        let engine = ArchiveEngine(); engine.reduced = false; engine.targetReveal = 1
        engine.select(0, time: 0)
        var time = 0.0
        func settle(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { time += 1.0 / 60; engine.tick(time: time, dt: 1.0 / 60) } }
        settle(6); engine.setDetail(true, time: time); settle(6)
        XCTAssertTrue(engine.canInspect)
        let camera = engine.makeFrame(aspect: 16.0 / 9.0).cameraPosition
        engine.beginMusicInspection(); engine.inspect(dx: 20000, dy: -10000); settle(3)
        let changed = engine.makeFrame(aspect: 16.0 / 9.0)
        XCTAssertLessThanOrEqual(abs(changed.cards[0].yaw), 0.951)
        XCTAssertLessThanOrEqual(abs(changed.cards[0].tilt), 0.221)
        XCTAssertGreaterThan(abs(changed.cards[0].yaw), 0.8)
        XCTAssertLessThan(simd_distance(changed.cameraPosition, camera), 0.01)
        engine.resetMusicInspection(); settle(3)
        XCTAssertLessThan(abs(engine.makeFrame(aspect: 16.0 / 9.0).cards[0].yaw), 0.001)
    }
}
