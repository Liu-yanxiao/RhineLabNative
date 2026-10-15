import XCTest
@testable import RhineLab

@MainActor final class ShelfMomentumTests: XCTestCase {
    func testReleaseVelocityUsesTheLatestDirectionAndIgnoresAPause() {
        var samples = MusicShelfVelocity(); samples.start(time: 1)
        samples.record(SIMD2(0.3, 0.6), time: 1.02)
        samples.record(SIMD2(0.5, 1), time: 1.04)
        samples.record(SIMD2(0.4, 0.7), time: 1.06)
        let reversed = samples.released(at: 1.061)
        XCTAssertLessThan(reversed.x, 0); XCTAssertLessThan(reversed.y, 0)
        XCTAssertEqual(samples.released(at: 1.2), .zero, "holding still before release must not launch an old fling")
        samples.start(time: 2)
        samples.record(SIMD2(100, 1000), time: 2.01)
        let spike = samples.released(at: 2.011)
        XCTAssertLessThanOrEqual(abs(spike.x), 8)
        XCTAssertLessThanOrEqual(abs(spike.y), 32)
        XCTAssertEqual(spike.y / spike.x, 10, accuracy: 0.001)
    }
    func testMomentumKeepsDiagonalDirectionAndSettlesAtDifferentRefreshRates() {
        var stops: [SIMD2<Float>] = []
        for hz in [60, 120] {
            var motion = MusicShelfMomentum(value: SIMD2(0.2, 0.3), velocity: SIMD2(1, 4), reduced: false)
            let initial = motion.value
            for _ in 0..<(hz / 10) { motion.step(dt: 1 / Float(hz), reduced: false) }
            let travel = motion.value - initial
            XCTAssertGreaterThan(travel.x, 0)
            XCTAssertEqual(travel.y / travel.x, 4, accuracy: 0.001)
            for _ in 0..<(hz * 8) { motion.step(dt: 1 / Float(hz), reduced: false) }
            XCTAssertEqual(motion.phase, .idle); XCTAssertEqual(motion.velocity, .zero)
            XCTAssertEqual(motion.value.x, motion.value.x.rounded())
            XCTAssertEqual(motion.value.y, motion.value.y.rounded())
            stops.append(motion.value)
        }
        XCTAssertEqual(stops[0], stops[1], "60Hz and 120Hz must land on the same track")
    }
    func testFasterReleaseTravelsFartherAndReducedMotionSkipsCoasting() {
        func settle(_ velocity: Float, reduced: Bool = false) -> SIMD2<Float> {
            var motion = MusicShelfMomentum(value: SIMD2(0.2, 0.2), velocity: SIMD2(0, velocity), reduced: reduced)
            if reduced { XCTAssertNotEqual(motion.phase, .coasting) }
            for _ in 0..<600 { motion.step(dt: 1.0 / 60, reduced: reduced) }
            XCTAssertEqual(motion.phase, .idle)
            return motion.value
        }
        XCTAssertGreaterThan(settle(10).y, settle(2).y + 2)
        XCTAssertEqual(settle(10, reduced: true), .zero)
    }
    private func engine() -> ArchiveEngine {
        let engine = ArchiveEngine(); engine.targetReveal = 1; engine.idleDrift = false
        for frame in 0..<480 { engine.tick(time: Double(frame) / 60, dt: 1.0 / 60) }
        return engine
    }
    func testPressingAgainImmediatelyHoldsTheMovingShelf() {
        let engine = engine()
        engine.beginBrowse(); _ = engine.moveBrowse(by: SIMD2(0.2, 0.3))
        engine.endBrowse(velocity: SIMD2(1, 8))
        for frame in 0..<8 { engine.tick(time: 8 + Double(frame) / 60, dt: 1.0 / 60) }
        let caught = engine.browsePosition
        XCTAssertTrue(engine.beginBrowse())
        for frame in 8..<28 { engine.tick(time: 8 + Double(frame) / 60, dt: 1.0 / 60) }
        XCTAssertEqual(engine.browsePosition, caught)
        XCTAssertNil(engine.takeMomentumSelection())
        engine.endBrowse()
        for frame in 28..<628 { engine.tick(time: 8 + Double(frame) / 60, dt: 1.0 / 60) }
        XCTAssertFalse(engine.isAnimating)
    }
    func testMomentumSelectionUpdatesCannotOverrideANewerClick() throws {
        let engine = engine()
        engine.beginBrowse(); _ = engine.moveBrowse(by: SIMD2(0.2, 0.3))
        engine.endBrowse(velocity: SIMD2(1, 12))
        var updates: [ArchiveEngine.BrowseSelection] = []
        for frame in 0..<60 {
            engine.tick(time: 8 + Double(frame) / 60, dt: 1.0 / 60)
            if let update = engine.takeMomentumSelection() {
                XCTAssertTrue(engine.isCurrent(update))
                XCTAssertEqual(update.cell.lane, Int(engine.browsePosition.x.rounded()))
                XCTAssertEqual(update.cell.row, Int(engine.browsePosition.y.rounded()))
                updates.append(update)
            }
        }
        XCTAssertGreaterThan(updates.count, 2)
        let last = try XCTUnwrap(updates.last)
        engine.select(0, time: 9)
        XCTAssertFalse(engine.isCurrent(last), "a queued inertia update must not undo a later user selection")
        engine.tick(time: 9.02, dt: 0.02)
        XCTAssertNil(engine.takeMomentumSelection())
    }
}
