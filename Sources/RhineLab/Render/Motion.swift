import Foundation

/// Motion curves ported from the web version (`src/motion.ts`).
enum Motion {
    static let inspectionLift: Float = 4.05

    static func smooth(_ t: Float) -> Float {
        let t = max(0, min(1, t))
        return t * t * t * (10 + t * (-15 + 6 * t))
    }

    private static func bell(_ x: Float, _ width: Float) -> Float {
        exp(-0.5 * (x / width) * (x / width))
    }

    /// Static "shoulder" around the selected row, evaluated at the settled time 26.56.
    static func settlingWave(distance: Float, time: Float = 26.56) -> Float {
        let age = time - 25.05 - abs(distance) * 0.065
        let envelope = max(-0.42, 2.15 - 0.17 * ((distance * distance + 1).squareRoot() - 1))
        let rise = smooth(age / 0.62)
        let ring: Float = age > 0 ? sin(age * 5.1) * exp(-age * 1.3) : 0
        return envelope * (rise + 0.18 * ring * smooth(age / 0.16))
    }

    static func selectionWave(distance: Float, age: Float) -> Float {
        if age < 0 || age > 3.2 { return 0 }
        return 0.8 * smooth(age / 0.2) * exp(-age * 1.15)
            * cos((distance - age * 8) * 0.58) * bell(distance - age * 8, 3.4)
    }

    static func columnStrength(lane: Float, focus: Float) -> Float {
        0.25 + 0.75 * bell(lane - focus, 0.55)
    }

    static func idleWave(row: Float, lane: Float, time: Float) -> Float {
        0.075 * sin(time * .pi * 2 / 8 + row * 0.3 - lane * 0.45)
            + 0.027 * sin(time * .pi * 2 / 13 - row * 0.17 + lane * 0.3)
    }

    /// Critically damped spring step (same integrator as the web version).
    struct Spring {
        var value: Float
        var velocity: Float = 0

        mutating func damp(to target: Float, rate: Float, dt: Float) {
            let delta = value - target
            let impulse = velocity + rate * delta
            let decay = exp(-rate * dt)
            value = target + (delta + impulse * dt) * decay
            velocity = (velocity - rate * impulse * dt) * decay
        }
    }

    /// Rotation returns to zero before the card is allowed to descend.
    static func returnStep(_ angle: Float, dt: Float, reduced: Bool) -> Float {
        let next = angle * exp(-dt * (reduced ? 35 : 7))
        return abs(next) <= 0.001 ? 0 : next
    }
}
