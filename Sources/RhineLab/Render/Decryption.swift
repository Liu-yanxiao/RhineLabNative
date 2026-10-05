import Foundation
import simd

/// The "decryption" cue played when a file opens: scan lines join across the card, hold, retract,
/// then the frosted glass clears. Times are original-video seconds (ported from `decryption.ts`).
enum Decryption {
    static let start: Float = 34.12
    static let end: Float = 39.56
    /// Interactive playback runs 1.5× faster than the reference video.
    static let rate: Float = 1.5
    static var duration: Float { (end - start) / rate }

    static let scanFrom = SIMD2<Float>(-1.6, 0.5)
    static let scanTo = SIMD2<Float>(1.98, 3.24)
    static let corners: [SIMD2<Float>] = [[-1.88, 3.2], [2.14, 3.36], [-1.77, 0.36], [2.17, 0.65]]

    private typealias Knot = (t: Float, v: Float)
    private static let grow: [Knot] = [(34.24, 0), (34.4, 0.19), (34.64, 0.57), (34.96, 0.79), (35.28, 0.92), (35.6, 0.973), (36.04, 1)]
    private static let reveal: [Knot] = [(38.84, 0), (38.92, 0.28), (39.0, 0.51), (39.16, 0.74), (39.32, 0.94), (39.56, 1)]
    private static let retract: [Knot] = [(37.72, 1), (37.88, 0.72), (38.0, 0.38), (38.12, 0.22), (38.24, 0.14), (38.4, 0.075), (38.64, 0.024), (38.84, 0)]

    enum Phase { case waiting, joining, connected, retracting, revealing, clear }

    struct Frame {
        var time: Float
        var intervals: [(Float, Float)]
        var markers: Float
        var point: Float
        var label: Float
        var labelValue: Float
        var clarity: Float
        var phase: Phase
    }

    /// Monotone cubic Hermite interpolation: keeps the measured easing without overshoot.
    private static func sample(_ knots: [Knot], _ time: Float) -> Float {
        if time <= knots[0].t { return knots[0].v }
        if time >= knots[knots.count - 1].t { return knots[knots.count - 1].v }
        func secant(_ i: Int) -> Float { (knots[i + 1].v - knots[i].v) / (knots[i + 1].t - knots[i].t) }
        func slope(_ i: Int) -> Float {
            if i == 0 || i == knots.count - 1 { return 0 }
            let a = secant(i - 1), b = secant(i)
            if a * b <= 0 { return 0 }
            let left = knots[i].t - knots[i - 1].t, right = knots[i + 1].t - knots[i].t
            let w1 = 2 * right + left, w2 = right + 2 * left
            return (w1 + w2) / (w1 / a + w2 / b)
        }
        var i = 0
        while time > knots[i + 1].t { i += 1 }
        let span = knots[i + 1].t - knots[i].t
        let t = (time - knots[i].t) / span, t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * knots[i].v + (t3 - 2 * t2 + t) * span * slope(i)
            + (-2 * t3 + 3 * t2) * knots[i + 1].v + (t3 - t2) * span * slope(i + 1)
    }

    static func frame(_ time: Float) -> Frame {
        let grown = sample(grow, time)
        let remaining = sample(retract, time)
        var intervals: [(Float, Float)] = []
        if time >= 34.24 && time < 36.04 && grown > 0 {
            intervals = [(0, grown * 0.5), (1 - grown * 0.5, 1)]
        } else if time >= 36.04 && time < 38.84 {
            intervals = [(0.5 - remaining * 0.5, 0.5 + remaining * 0.5)]
        }
        let s = Motion.smooth
        let phase: Phase = time < 34.24 ? .waiting : time < 36.04 ? .joining : time < 37.72 ? .connected
            : time < 38.84 ? .retracting : time < end ? .revealing : .clear
        return Frame(
            time: time, intervals: intervals,
            markers: s((time - 34.2) / 0.12) * (1 - s((time - 37.76) / 0.56)),
            point: s((time - 38.58) / 0.2) * (1 - s((time - 39.08) / 0.22)),
            label: s((time - 34.32) / 0.36) * (1 - s((time - 37.68) / 0.24)),
            labelValue: s((time - 35.64) / 0.56),
            clarity: sample(reveal, time), phase: phase)
    }

    /// Everything the interface overlay needs, in normalised device coordinates.
    struct Overlay {
        var frame = Decryption.frame(-1)
        var segments: [(SIMD2<Float>, SIMD2<Float>)] = []
        var corners: [SIMD2<Float>] = []
        var center = SIMD2<Float>(0, 0)
        /// 0 = text fully redacted, 1 = fully readable.
        var documentProgress: Float = 1
        var active = false
        var finished: Bool { !active || (frame.phase == .clear && documentProgress >= 1) }
    }
}
