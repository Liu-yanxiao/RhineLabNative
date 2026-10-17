import XCTest
import simd
import SwiftUI
@testable import RhineLab

@MainActor final class HoverTests: XCTestCase {
    func testMouseMovementThroughTheSwiftUIStagePreviewsAndReleasesTheCard() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let renderer = try XCTUnwrap(MetalRenderer(modelDirectory: root.appendingPathComponent("Resources/Models")))
        let previousHeadless = AppModel.headless
        AppModel.headless = true
        defer { AppModel.headless = previousHeadless }
        let model = AppModel(renderer: renderer)
        model.reduced = false; model.idleDrift = false
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1440, height: 810),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.acceptsMouseMovedEvents, "the window must request real mouse movement events")
        var time = CACurrentMediaTime()
        func advance(_ count: Int) {
            for _ in 0..<count { time += 1.0 / 60; model.engine.tick(time: time, dt: 1.0 / 60) }
        }
        advance(480)
        let original = model.engine.makeFrame(aspect: 16.0 / 9.0)
        let location = Archive.location(of: model.selected)
        let selectedCell = Cell(lane: location.lane, row: location.row)
        var target: (point: CGPoint, index: Int)?
        for y in stride(from: 300, through: 800, by: 40) {
            for x in stride(from: 220, through: 880, by: 40) {
                let ndc = SIMD2(Float(x) / 960 - 1, 1 - Float(y) / 540)
                if let hit = model.engine.pick(ndc: ndc, aspect: 16.0 / 9.0), hit.cell != selectedCell {
                    let viewPoint = CGPoint(x: CGFloat(x) / 1920 * model.sceneView.bounds.width,
                                            y: (1 - CGFloat(y) / 1080) * model.sceneView.bounds.height)
                    target = (model.sceneView.convert(viewPoint, to: nil), hit.index)
                    break
                }
            }
            if target != nil { break }
        }
        let hitTarget = try XCTUnwrap(target, "fixture must contain a visible unselected card")
        func move(_ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: time,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 77, clickCount: 0, pressure: 0)!
            NSApp.postEvent(event, atStart: true)
            while let next = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.005), inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
            }
        }
        move(hitTarget.point); advance(18)
        XCTAssertEqual(model.hover, hitTarget.index, "the transparent SwiftUI stage must not hide scene mouse movement")
        let preview = model.engine.makeFrame(aspect: 16.0 / 9.0)
        func greatestLift(_ frame: RenderFrame) -> Float {
            frame.arrayCards.compactMap { card -> Float? in
                original.arrayCards.first(where: { abs($0.x - card.x) < 0.001 && abs($0.z - card.z) < 0.001 }).map { card.y - $0.y }
            }.max() ?? 0
        }
        XCTAssertGreaterThan(greatestLift(preview), 0.15, "hovering must visibly lift a card before clicking")
        let outside = model.sceneView.convert(CGPoint(x: model.sceneView.bounds.width * 0.9,
                                                      y: model.sceneView.bounds.height * 0.85), to: nil)
        move(outside); advance(24)
        XCTAssertNil(model.hover, "moving over the interface must clear the preview")
        XCTAssertLessThan(greatestLift(model.engine.makeFrame(aspect: 16.0 / 9.0)), 0.01)
        XCTAssertEqual(model.selected, original.cards[0].labelIndex, "hover preview must not change the selected song")
        move(hitTarget.point)
        XCTAssertNotNil(model.hover)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(model.hover, "switching away from the window must release the hovered card")
        move(hitTarget.point)
        XCTAssertNotNil(model.hover)
        model.present(.search)
        XCTAssertNil(model.hover, "opening a modal must release the hovered card")
        model.dismissModal(); move(hitTarget.point)
        XCTAssertNotNil(model.hover)
        window.contentView = nil
        XCTAssertNil(model.hover, "detaching the scene from a window must release the preview")
    }
    func testBreathingRemainsSmoothAfterLongSystemUptime() {
        let engine = ArchiveEngine(); engine.targetReveal = 1; engine.idleDrift = true; engine.reduced = false
        let start = 1_336_000.0
        engine.select(0, time: start)
        for i in 0..<600 { engine.tick(time: start + Double(i) / 60, dt: 1.0 / 60) }
        var positions: [Float] = []
        for i in 600..<720 {
            engine.tick(time: start + Double(i) / 60, dt: 1.0 / 60)
            positions.append(engine.makeFrame(aspect: 16.0 / 9.0).cards[0].position.y)
        }
        let changed = zip(positions, positions.dropFirst()).filter { abs($0 - $1) > 0.000001 }.count
        print("long uptime breathing: \(changed) changing steps out of 119")
        XCTAssertGreaterThan(changed, 110, "60Hz rendering must not repeat an 8Hz animation phase")
        XCTAssertLessThan(zip(positions, positions.dropFirst()).map { abs($0 - $1) }.max() ?? 1, 0.004)
    }
    func testMusicBreathingDoesNotInheritTheDisabledArchivePreference() {
        let name = "RhineBreathingTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "rhine-idle")
        XCTAssertTrue(AppModel.loadIdleDrift(from: defaults))
        defaults.set(false, forKey: "rhine-music-idle-1")
        XCTAssertFalse(AppModel.loadIdleDrift(from: defaults))
    }

    func testMainBreathesWithoutPlaybackAndDetailSettles() {
        let engine = ArchiveEngine(); engine.targetReveal = 1; engine.idleDrift = true
        engine.reduced = false; engine.setMusicPlaying(false); engine.select(0, time: 0)
        var time = 0.0
        func advance(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { time += 1.0 / 60; engine.tick(time: time, dt: 1.0 / 60) } }
        advance(10)
        let before = engine.makeFrame(aspect: 16.0 / 9.0).arrayCards
        advance(2)
        let after = engine.makeFrame(aspect: 16.0 / 9.0).arrayCards
        XCTAssertTrue(engine.isAnimating)
        XCTAssertGreaterThan(zip(before, after).map { abs($0.y - $1.y) }.max() ?? 0, 0.01)
        engine.setDetail(true, time: time); advance(10)
        XCTAssertFalse(engine.isAnimating)
    }
    func testMainPlaybackDoesNotFallToTwentyFramesWhenSettled() {
        XCTAssertEqual(ArchiveView.musicFrameRate(idle: true, detail: false), ArchiveView.musicFrameRate(idle: false, detail: false))
        XCTAssertGreaterThanOrEqual(ArchiveView.musicFrameRate(idle: true, detail: false), 60)
    }
    func testMusicHoverDoesNotSwitchOcclusionWhenSettling() {
        for level in 0...3 {
            XCTAssertEqual(ArchiveView.adaptiveEffectsOff(level: level, moving: true) & 2,
                           ArchiveView.adaptiveEffectsOff(level: level, moving: false) & 2,
                           "same pose must keep the same occlusion while hover settles")
        }
    }
    func testSteadyPointerDoesNotOscillateBetweenRaisedCards() {
        let library = MusicLibrary(storageURL: nil, migrate: false)
        _ = library
        let engine = ArchiveEngine(); engine.targetReveal = 1; engine.idleDrift = false
        engine.select(0, time: 0)
        var time = 0.0
        func tick() { time += 1.0 / 60; engine.tick(time: time, dt: 1.0 / 60) }
        for _ in 0..<480 { tick() }
        var worst = 0
        for row in 0..<10 {
            for column in 0..<16 {
                engine.setHover(nil); for _ in 0..<18 { tick() }
                let point = SIMD2<Float>(-0.85 + Float(column) * 0.055, -0.62 + Float(row) * 0.12)
                var previous: Cell?, changes = 0
                for _ in 0..<36 {
                    let hit = engine.pick(ndc: point, aspect: 16.0 / 9.0)?.cell
                    if let previous, previous != hit { changes += 1 }
                    previous = hit; engine.setHover(hit); tick()
                }
                worst = max(worst, changes)
                if changes > 4 {
                    XCTFail("stationary pointer \(point) changed target \(changes) times")
                    return
                }
            }
        }
        print("hover replay: maximum target changes \(worst)")
    }
}
