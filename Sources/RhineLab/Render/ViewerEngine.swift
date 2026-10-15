import Foundation
import simd

/// The 360° object study: one archive model at the origin, an orbit camera and the exploded
/// assembly spread. Ported from the web version's `model-viewer.ts` and `viewer-camera.ts`.
final class ViewerEngine {
    struct Part { let id: String; let label: String; let en: String; let depth: Float }
    static let parts: [Part] = [
        Part(id: "fasteners", label: "紧固件", en: "FASTENERS", depth: 2.75),
        Part(id: "cover", label: "透明盖板", en: "OPTICAL COVER", depth: 1.85),
        Part(id: "optical-lenses", label: "折射环组", en: "REFRACTIVE RINGS", depth: 0.75),
        Part(id: "optical-core", label: "光学核心", en: "OPTICAL CORE", depth: -0.15),
        Part(id: "substrate", label: "信息基板", en: "SUBSTRATE", depth: -1.1),
        Part(id: "carrier", label: "背板与框架", en: "CARRIER", depth: -2.05),
    ]
    static func depth(of part: String) -> Float { parts.first { $0.id == part }?.depth ?? 1.85 }

    /// The card (0...3.7 tall) is centred on the origin.
    static let modelOffset = SIMD3<Float>(0, -1.85, 0)
    static let fovY: Float = 34 * .pi / 180
    static let near: Float = 0.3, far: Float = 120
    static let minDistance: Float = 5, maxDistance: Float = 28, maxFocusRadius: Float = 5
    static let initialPosition = SIMD3<Float>(7.2, 3.8, 12)
    static let background = ArchiveEngine.lightBackground
    static let darkBackground = SIMD3<Float>(0x11, 0x18, 0x1b) / 255
    static let darkFog = SIMD3<Float>(0x26, 0x31, 0x36) / 255
    /// 0 light ... 1 dark, set when the study opens (the theme cannot change while it is open).
    var theme: Float = 0

    /// Camera pose about the focus point (three.js Spherical: phi from +Y, theta about Y from +Z).
    struct Spherical {
        var radius: Float, phi: Float, theta: Float
        init(radius: Float, phi: Float, theta: Float) { self.radius = radius; self.phi = phi; self.theta = theta }
        init(_ v: SIMD3<Float>) {
            radius = max(1e-4, simd_length(v))
            phi = acos(max(-1, min(1, v.y / radius)))
            theta = atan2(v.x, v.z)
        }
        var vector: SIMD3<Float> {
            SIMD3(radius * sin(phi) * sin(theta), radius * cos(phi), radius * sin(phi) * cos(theta))
        }
        mutating func makeSafe() { phi = max(0.02, min(.pi - 0.02, phi)) }
    }

    private let lock = NSRecursiveLock()
    private(set) var isOpen = false
    private(set) var labelIndex = 0
    var reduced = false
    var musicDetail = false
    private var musicPlaying = false
    private var musicGain: Float = 0
    private var pendingLabel: Int?
    private var swapElapsed: Float = 1
    private var musicBackdrop: [(position: SIMD4<Float>, theme: Float, label: Int)] = []
    func setMusicBackdrop(_ frame: RenderFrame) {
        lock.lock(); defer { lock.unlock() }
        guard let selected = frame.cards.first else { return }
        let anchor = selected.position + SIMD3<Float>(0, 1.85, 0)
        musicBackdrop = frame.arrayCards.enumerated().compactMap { index, card in
            let p = SIMD3(card.x, card.y, card.z) - anchor
            guard simd_length(p) < 22 else { return nil }
            return (SIMD4(p, card.w), frame.arrayTheme.indices.contains(index) ? frame.arrayTheme[index] : theme,
                    frame.arrayLabels.indices.contains(index) ? frame.arrayLabels[index] : 0)
        }
    }
    var isMusicPlaybackOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        return musicDetail && musicPlaying && !reduced && !resetting && pendingLabel == nil && swapElapsed >= 0.64
            && abs(goalRoll - poseRoll) < 0.00001 && simd_distance_squared(focus, goalFocus) < 1e-10
            && abs(log(pose.radius) - log(goal.radius)) < 1e-4 && abs(pose.phi - goal.phi) < 1e-4
            && abs(atan2(sin(goal.theta - pose.theta), cos(goal.theta - pose.theta))) < 1e-4
    }
    func setMusicPlaying(_ playing: Bool) { lock.lock(); defer { lock.unlock() }; musicPlaying = playing; wake() }
    var onActivityChanged: ((Bool) -> Void)?
    var onStatusChanged: ((String) -> Void)?
    private(set) var isAnimating = false
    private var now: Double = 0

    // Requested pose (what the controls set) and the rendered pose that follows it.
    private var goal = Spherical(ViewerEngine.initialPosition)
    private var goalFocus = SIMD3<Float>(repeating: 0)
    private var pose = Spherical(ViewerEngine.initialPosition)
    private var focus = SIMD3<Float>(repeating: 0)
    private var goalRoll: Float = 0
    private var poseRoll: Float = 0
    private var resetFrom = Spherical(ViewerEngine.initialPosition)
    private var resetFocus = SIMD3<Float>(repeating: 0)
    private var resetElapsed: Float = 0
    private(set) var resetting = false

    private var spread = Motion.Spring(value: 0)
    private(set) var targetSpread: Float = 0
    private var clarity = Motion.Spring(value: 1)
    private(set) var targetClarity: Float = 1
    private(set) var status = "已组装"

    // MARK: Lifecycle

    func open(labelIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        self.labelIndex = labelIndex
        isOpen = true
        spread = Motion.Spring(value: 0); targetSpread = 0
        clarity = Motion.Spring(value: 1); targetClarity = 1
        setStatus("已组装")
        reset(animated: false)
        wake()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        isOpen = false
        resetting = false
    }

    func selectLabel(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        if musicDetail && !reduced && labelIndex != index {
            pendingLabel = index; swapElapsed = 0
        } else { labelIndex = index; pendingLabel = nil; swapElapsed = 1 }
        wake()
    }

    func wake() {
        lock.lock(); defer { lock.unlock() }
        if !isAnimating { isAnimating = true; onActivityChanged?(true) }
    }

    // MARK: Controls (main thread)

    func setExploded(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        targetSpread = on ? 1 : 0
        setStatus(on ? "正在拆解" : (spread.value > 0.001 ? "正在重组" : "已组装"))
        if reduced { spread = Motion.Spring(value: targetSpread) }
        wake()
    }

    func setClear(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        targetClarity = on ? 1 : 0
        if reduced { clarity = Motion.Spring(value: targetClarity) }
        wake()
    }

    /// Mouse drag in points; `viewHeight` scales the gesture like OrbitControls does.
    func orbit(dx: Float, dy: Float, viewHeight: Float) {
        lock.lock(); defer { lock.unlock() }
        interruptReset()
        let k = 2 * Float.pi / max(1, viewHeight) * 0.65
        goal.theta -= dx * k
        goal.phi -= dy * k
        if !musicDetail { goal.makeSafe() }
        wake()
    }

    func roll(by radians: Float) {
        lock.lock(); defer { lock.unlock() }
        guard radians.isFinite else { return }
        interruptReset(); goalRoll += radians; wake()
    }

    /// Screen-space pan by a mouse drag in points.
    func pan(dx: Float, dy: Float, viewHeight: Float) {
        lock.lock(); defer { lock.unlock() }
        interruptReset()
        let targetDistance = goal.radius * tan(Self.fovY / 2) * 0.7
        let (right, up) = axes()
        move(by: right * (-2 * dx * targetDistance / max(1, viewHeight)) + up * (2 * dy * targetDistance / max(1, viewHeight)))
    }

    /// Arrow keys: a step of 2.5 % of the orbit distance along the camera axes.
    func panStep(_ direction: SIMD2<Float>) {
        lock.lock(); defer { lock.unlock() }
        interruptReset()
        let (right, up) = axes()
        let step = goal.radius * 0.025
        move(by: right * (direction.x * step) + up * (direction.y * step))
    }

    /// Multiply the orbit distance (wheel, +/- keys); clamped to 5...28.
    func dolly(factor: Float) {
        lock.lock(); defer { lock.unlock() }
        interruptReset()
        let next = goal.radius * factor
        guard next.isFinite, next > 0 else { return }
        goal.radius = musicDetail ? max(0.5, next) : max(Self.minDistance, min(Self.maxDistance, next))
        wake()
    }

    func dolly(scrollDelta: Float, precise: Bool) {
        // One wheel notch zooms like a 100 px browser wheel event; trackpad deltas are pixels.
        let amount = precise ? abs(scrollDelta) * 0.01 : abs(scrollDelta)
        let scale = pow(0.95, 0.7 * amount)
        dolly(factor: scrollDelta > 0 ? 1 / scale : scale)
    }

    func reset(animated: Bool) {
        lock.lock(); defer { lock.unlock() }
        goalFocus = .zero
        goalRoll = 0
        goal = Spherical(musicDetail ? SIMD3<Float>(-1.45, 3.79, 10.39) : Self.initialPosition)
        if animated && !reduced {
            resetFrom = pose
            resetFocus = focus
            resetElapsed = 0
            resetting = true
        } else {
            resetting = false
            pose = goal
            focus = goalFocus
            poseRoll = 0
        }
        wake()
    }

    private func interruptReset() {
        guard resetting else { return }
        resetting = false
        goal = pose
        goalFocus = focus
    }

    /// Right and up axes of the rendered camera.
    private func axes() -> (SIMD3<Float>, SIMD3<Float>) {
        let z = simd_normalize(pose.vector)
        let x = simd_normalize(simd_cross(cameraUp, z))
        return (x, simd_cross(z, x))
    }

    private var cameraUp: SIMD3<Float> {
        let up: SIMD3<Float> = musicDetail ? SIMD3(-cos(pose.phi) * sin(pose.theta), sin(pose.phi), -cos(pose.phi) * cos(pose.theta)) : SIMD3(0, 1, 0)
        return up * cos(poseRoll) + simd_normalize(simd_cross(up, pose.vector)) * sin(poseRoll)
    }

    /// Clamp the requested focus to a 5-unit radius and move the camera by the same amount,
    /// so the orbit radius is preserved at the panning limit.
    private func move(by delta: SIMD3<Float>) {
        var next = goalFocus + delta
        let len = simd_length(next)
        if !musicDetail, len > Self.maxFocusRadius { next *= Self.maxFocusRadius / len }
        goalFocus = next
        wake()
    }

    private func setStatus(_ s: String) {
        guard s != status else { return }
        status = s
        onStatusChanged?(s)
    }

    // MARK: Per-frame update (render thread)

    func tick(time: Double, dt rawDt: Double) {
        lock.lock(); defer { lock.unlock() }
        now = time
        let dt = Float(min(rawDt, 0.05))
        musicGain += ((musicPlaying && !reduced ? 1 : 0) - musicGain) * (1 - exp(-5 * dt))
        if swapElapsed < 0.64 {
            swapElapsed += dt
            if swapElapsed >= 0.20, let index = pendingLabel { labelIndex = index; pendingLabel = nil }
        }
        poseRoll += (goalRoll - poseRoll) * (reduced ? 1 : 1 - exp(-9 * dt))
        if abs(goalRoll - poseRoll) < 0.00001 { poseRoll = goalRoll }

        if reduced {
            spread = Motion.Spring(value: targetSpread)
            clarity = Motion.Spring(value: targetClarity)
        } else {
            spread.damp(to: targetSpread, rate: 5.5, dt: dt)
            clarity.damp(to: targetClarity, rate: 8, dt: dt)
        }
        if abs(spread.value - targetSpread) < 0.0001 && abs(spread.velocity) < 0.001 {
            spread = Motion.Spring(value: targetSpread)
            setStatus(targetSpread > 0.5 ? "已拆解" : "已组装")
        }
        if abs(clarity.value - targetClarity) < 0.0001 && abs(clarity.velocity) < 0.001 {
            clarity = Motion.Spring(value: targetClarity)
        }

        if reduced {
            resetting = false
            pose = goal; focus = goalFocus
        } else if resetting {
            resetElapsed += max(0, dt)
            let t = min(1, resetElapsed / 0.56)
            let p = 1 - pow(1 - t, 3)
            focus = simd_mix(resetFocus, goalFocus, SIMD3(repeating: p))
            interpolate(from: resetFrom, to: goal, angle: p, radius: p)
            if t >= 1 { resetting = false }
        } else {
            let panBlend = 1 - exp(-13 * dt), orbitBlend = 1 - exp(-9 * dt), zoomBlend = 1 - exp(-15 * dt)
            focus = simd_mix(focus, goalFocus, SIMD3(repeating: panBlend))
            interpolate(from: pose, to: goal, angle: orbitBlend, radius: zoomBlend)
            if simd_distance_squared(focus, goalFocus) < 1e-10 { focus = goalFocus }
        }
        updateActivity()
    }

    private func interpolate(from: Spherical, to: Spherical, angle: Float, radius: Float) {
        // Logarithmic distance keeps zoom in and zoom out symmetric.
        pose.radius = exp(log(from.radius) + (log(to.radius) - log(from.radius)) * radius)
        pose.phi = from.phi + (to.phi - from.phi) * angle
        let dTheta = atan2(sin(to.theta - from.theta), cos(to.theta - from.theta))
        pose.theta = from.theta + dTheta * angle
        if !musicDetail { pose.makeSafe() }
    }

    private func updateActivity() {
        var moving = resetting || abs(goalRoll - poseRoll) > 0.00001 || swapElapsed < 0.64 || musicGain > 0.002 || (musicPlaying && !reduced)
        if abs(spread.value - targetSpread) > 0 || abs(clarity.value - targetClarity) > 0 { moving = true }
        if simd_distance_squared(focus, goalFocus) > 1e-10 { moving = true }
        if abs(log(pose.radius) - log(goal.radius)) > 1e-4 || abs(pose.phi - goal.phi) > 1e-4
            || abs(atan2(sin(goal.theta - pose.theta), cos(goal.theta - pose.theta))) > 1e-4 { moving = true }
        if moving != isAnimating { isAnimating = moving; onActivityChanged?(moving) }
    }

    // MARK: Frame output

    var cameraPosition: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return pose.vector + focus }

    func makeFrame(aspect: Float) -> RenderFrame {
        lock.lock(); defer { lock.unlock() }
        var f = RenderFrame()
        let eye = pose.vector + focus
        f.view = Matrix.lookAt(eye: eye, target: focus, up: cameraUp)
        let far = musicDetail ? max(Self.far, simd_length(eye) + 20) : Self.far
        f.proj = Matrix.perspective(fovY: Self.fovY, aspect: aspect, near: Self.near, far: far)
        if musicDetail { f.proj[2][0] = 0.49 }
        f.cameraPosition = eye
        // The detail scene's gentle haze, kept relative to the object so zooming never washes it out.
        let objectDistance = simd_length(eye)
        f.fogNear = max(0, objectDistance - 1)
        f.fogFar = objectDistance + 12
        f.focusDistance = objectDistance
        f.depthOfField = 0
        f.near = Self.near
        f.far = far
        f.effectsOff = 6        // ambient occlusion and depth of field are array-only effects
        f.themeAmount = theme
        f.background = simd_mix(Self.background, Self.darkBackground, SIMD3(repeating: theme))
        f.fogColor = simd_mix(Self.background, Self.darkFog, SIMD3(repeating: theme))
        let swap: Float = swapElapsed < 0.20 ? -0.65 * (swapElapsed / 0.20) : -0.65 * pow(max(0, 1 - (swapElapsed - 0.20) / 0.44), 3)
        f.assembly = AssemblyDraw(spread: spread.value, clarity: clarity.value, labelIndex: labelIndex, theme: theme,
                                  offset: SIMD3(0, swap + 0.025 * sin(Motion.phase(time: now, period: 2 * .pi / 1.4)) * musicGain, 0))
        if musicDetail {
            for card in musicBackdrop {
                f.arrayCards.append(card.position); f.arrayTheme.append(card.theme)
                let index = card.label % MusicCatalog.items.count
                if MusicArtwork.image(index) != nil {
                    f.arrayPrints.append(CardDraw(position: SIMD3(card.position.x, card.position.y, card.position.z), tilt: card.position.w,
                                                 yaw: 0, quality: 0.85, reveal: 0, labelIndex: index, theme: theme))
                }
            }
        }
        f.time = Float(now)
        return f
    }
}
