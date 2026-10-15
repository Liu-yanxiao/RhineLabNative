import Foundation
import simd

/// Recent gesture samples in shelf cells. Reverse travel starts a fresh velocity estimate.
/// Adapted from LBEILC/RhineLabUI src/archive-drag.ts (MIT, LICENSE-RhineLabUI).
struct MusicShelfVelocity {
    private var samples: [(value: SIMD2<Float>, time: Double)] = []
    private var direction = SIMD2<Float>.zero
    private var lastMotion = -Double.infinity

    mutating func start(time: Double) {
        samples = [(.zero, time)]; direction = .zero; lastMotion = -.infinity
    }
    mutating func record(_ value: SIMD2<Float>, time: Double) {
        guard let previous = samples.last, time >= previous.time else { return }
        let delta = value - previous.value
        if simd_length_squared(delta) > 0.00000001 {
            lastMotion = time
            if simd_dot(delta, direction) < 0 { samples = [previous] }
            direction = delta
        }
        if previous.time == time { samples[samples.count - 1] = (value, time) }
        else { samples.append((value, time)) }
        samples = Array(samples.filter { time - $0.time <= 0.12 }.suffix(32))
    }
    func released(at time: Double) -> SIMD2<Float> {
        guard let first = samples.first, let last = samples.last,
              time - lastMotion <= 0.08, last.time - first.time >= 0.008 else { return .zero }
        let velocity = (last.value - first.value) / Float(last.time - first.time)
        guard velocity.x.isFinite, velocity.y.isFinite else { return .zero }
        // Bound extreme event spikes together, preserving the released screen direction.
        return velocity / max(1, abs(velocity.x) / 8, abs(velocity.y) / 32)
    }
}

/// Both tracks coast together, then settle onto the nearest cell with a damped spring.
/// The reference uses 2.4/s friction and a 10/s settling spring.
struct MusicShelfMomentum {
    enum Phase { case coasting, snapping, idle }
    private(set) var value: SIMD2<Float>
    private(set) var velocity: SIMD2<Float>
    private(set) var phase: Phase
    private var target: SIMD2<Float>

    init(value: SIMD2<Float>, velocity: SIMD2<Float>, reduced: Bool) {
        self.value = value
        self.velocity = reduced ? .zero : velocity
        phase = !reduced && max(abs(velocity.x), abs(velocity.y)) >= 0.75 ? .coasting : .snapping
        target = SIMD2(value.x.rounded(), value.y.rounded())
    }
    mutating func step(dt: Float, reduced: Bool) {
        if reduced && phase == .coasting {
            phase = .snapping; velocity = .zero
            target = SIMD2(value.x.rounded(), value.y.rounded())
        }
        if phase == .coasting {
            let decay = exp(-2.4 * dt)
            value += velocity * ((1 - decay) / 2.4); velocity *= decay
            if max(abs(velocity.x), abs(velocity.y)) < 0.6 {
                let resting = value + velocity / 2.4
                target = SIMD2(resting.x.rounded(), resting.y.rounded()); phase = .snapping
            }
        } else if phase == .snapping {
            var lane = Motion.Spring(value: value.x, velocity: velocity.x)
            var row = Motion.Spring(value: value.y, velocity: velocity.y)
            lane.damp(to: target.x, rate: reduced ? 35 : 10, dt: dt)
            row.damp(to: target.y, rate: reduced ? 35 : 10, dt: dt)
            value = SIMD2(lane.value, row.value); velocity = SIMD2(lane.velocity, row.velocity)
            if simd_length(value - target) < 0.0001 && simd_length(velocity) < 0.005 {
                value = target; velocity = .zero; phase = .idle
            }
        }
    }
}
