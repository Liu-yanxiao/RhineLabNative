import AppKit
import XCTest
@testable import RhineLab

private final class ArtworkFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static func reset() { lock.lock(); counts = [:]; lock.unlock() }
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.counts[path, default: 0] += 1; let count = Self.counts[path]!; Self.lock.unlock()
        let status = path == "/flaky" && count == 1 ? 503 : 200
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        let data = path.hasPrefix("/invalid") ? Data("not an image".utf8) : image
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ArtworkAndDragTests: XCTestCase {
    private func view() throws -> ArchiveView {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkFixtureProtocol.self]
        let renderer = try XCTUnwrap(MetalRenderer(compositeFormat: .bgra8Unorm, modelDirectory: root.appendingPathComponent("Resources/Models")))
        let view = ArchiveView(engine: ArchiveEngine(), viewer: ViewerEngine(), renderer: renderer,
                               artworkSession: URLSession(configuration: config))
        view.frame = CGRect(x: 0, y: 0, width: 1440, height: 810)
        view.clearMusicArtwork(); ArtworkFixtureProtocol.reset()
        return view
    }
    private func url(_ path: String) -> URL { URL(string: "https://artwork-fixture.invalid/" + UUID().uuidString + path)! }
    private func waitForImage(_ index: Int, seconds: Double = 2) async throws {
        let end = Date().addingTimeInterval(seconds)
        while MusicArtwork.image(index) == nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    }
    func testMalformedCoversDoNotBlockTheRemainingShelf() async throws {
        let view = try view()
        let root = "https://" + UUID().uuidString + ".invalid"
        view.prepareMusicArtwork(selected: 0, urls: [0: URL(string: root + "/invalid0")!, 1: URL(string: root + "/invalid1")!,
                                                   2: URL(string: root + "/invalid2")!, 3: URL(string: root + "/good")!])
        try await waitForImage(3)
        XCTAssertNotNil(MusicArtwork.image(3), "three undecodable responses must not occupy all download slots forever")
        view.clearMusicArtwork()
    }
    func testTemporaryFailureRecoversWithoutAnotherSelection() async throws {
        let view = try view()
        let address = URL(string: "https://" + UUID().uuidString + ".invalid/flaky")!
        view.prepareMusicArtwork(selected: 0, urls: [0: address])
        try await waitForImage(0)
        XCTAssertNotNil(MusicArtwork.image(0), "a transient cover failure should recover while the user stays on the same song")
        XCTAssertGreaterThanOrEqual(ArtworkFixtureProtocol.count("/flaky"), 2)
        view.clearMusicArtwork()
    }
    func testSelectedCoverSurvivesLoadingALargePlaylist() async throws {
        let view = try view()
        let urls = Dictionary(uniqueKeysWithValues: (0..<40).map { ($0, url("/cover-\($0)")) })
        view.prepareMusicArtwork(selected: 0, urls: urls)
        try await waitForImage(39)
        XCTAssertNotNil(MusicArtwork.image(39), "fixture must finish loading the playlist")
        XCTAssertNotNil(MusicArtwork.image(0), "loading later songs must not erase the selected home-page cover")
        view.clearMusicArtwork()
    }
    func testHomeMouseDragNavigatesWithoutOpeningACard() throws {
        let view = try view()
        view.engine.targetReveal = 1
        for frame in 0..<360 { view.engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        var selections = 0, opens = 0
        view.onSelect = { _, _ in selections += 1 }; view.onOpen = { opens += 1 }
        view.onBrowseSelect = { _, _ in selections += 1 }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 1,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 400, 400))
        view.mouseDragged(with: event(.leftMouseDragged, 600, 400))
        view.mouseUp(with: event(.leftMouseUp, 600, 400))
        XCTAssertGreaterThan(selections, 0, "home drag must browse songs or columns")
        XCTAssertEqual(opens, 0)
    }
    func testHeldInspectionFollowsThePointerWithinOneFrame() {
        let engine = ArchiveEngine(); engine.targetReveal = 1
        for frame in 0..<360 { engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        engine.setDetail(true, time: 6)
        for frame in 360..<720 { engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        XCTAssertTrue(engine.canInspect)
        engine.beginMusicInspection(); engine.inspect(dx: 100, dy: 0)
        engine.tick(time: 12, dt: 1.0 / 60)
        let yaw = engine.makeFrame(aspect: 16.0 / 9.0).cards[0].yaw
        print("held inspection first-frame response: \(yaw) radians / 0.32 target")
        XCTAssertGreaterThan(yaw, 0.12, "held rotation should follow input without the slow release easing")
    }
    func testShelfFollowsSubcellTravelAndSettlesAfterRelease() {
        let engine = ArchiveEngine(); engine.targetReveal = 1; engine.idleDrift = false
        for frame in 0..<480 { engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        let before = engine.makeFrame(aspect: 16.0 / 9.0).cards[0].position
        engine.beginBrowse(); _ = engine.moveBrowse(by: SIMD2(0.2, 0.3))
        engine.tick(time: 8, dt: 1.0 / 60)
        let during = engine.makeFrame(aspect: 16.0 / 9.0).cards[0].position
        XCTAssertEqual(during.x - before.x, -0.2 * Loop.columnSpacing, accuracy: 0.01)
        XCTAssertEqual(during.z - before.z, -0.3 * Loop.rowSpacing, accuracy: 0.01)
        engine.endBrowse()
        for frame in 481..<960 { engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        let after = engine.makeFrame(aspect: 16.0 / 9.0).cards[0].position
        XCTAssertEqual(after.x, before.x, accuracy: 0.01); XCTAssertEqual(after.z, before.z, accuracy: 0.01)
        XCTAssertFalse(engine.isAnimating)
    }
    func testVisibleCoversDoNotEvictEachOtherAndShrinkAfterLeaving() throws {
        let view = try view()
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try XCTUnwrap(context.makeImage())
        MusicArtwork.retainVisible(Set(0..<30))
        for index in 0..<30 { MusicArtwork.store(image, index: index) }
        XCTAssertEqual((0..<30).filter { MusicArtwork.image($0) != nil }.count, 30)
        MusicArtwork.retainVisible([])
        XCTAssertEqual((0..<30).filter { MusicArtwork.image($0) != nil }.count, 24)
        view.clearMusicArtwork()
    }
    func testReplacingCoverKeepsThePreviousTextureUntilUploadFinishes() throws {
        let view = try view(); view.engine.targetReveal = 1
        for frame in 0..<360 { view.engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        _ = ShotMode.capture(view.renderer, view.engine.makeFrame(aspect: 16.0 / 9.0), width: 320, height: 180)
        XCTAssertTrue(view.renderer.readyLabelIndices.contains(0))
        view.renderer.invalidateLabel(0)
        XCTAssertTrue(view.renderer.readyLabelIndices.contains(0), "upgrading artwork must not create a blank frame")
        view.clearMusicArtwork()
    }
}
