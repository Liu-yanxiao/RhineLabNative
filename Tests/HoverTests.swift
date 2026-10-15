import XCTest
import simd
@testable import RhineLab

@MainActor final class HoverTests: XCTestCase {
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
