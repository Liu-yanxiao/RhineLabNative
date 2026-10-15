import Foundation
import simd

private func ease(_ t: Float) -> Float { Motion.smooth(t) }
private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
private func v3(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }

/// The archive simulation: a looping grid of cards, the extracted card and the camera.
/// Motion is ported from the web version's `scene.ts`; drawing is done by `MetalRenderer`.
final class ArchiveEngine {
    /// The simulation runs on the render thread; input arrives on the main thread.
    private let lock = NSRecursiveLock()
    // Layout
    private var cells: [Cell] = []
    private var positions: [SIMD3<Float>] = []
    private var arrayTilt: [Float] = []
    private var arrayShown: [Bool] = []
    private var arrayOffsets: [SIMD3<Float>] = []   // world position after track / rail shift
    private var arrayTheme: [Float] = []
    private var theme = ThemeWave()
    private var watermark = SIMD4<Float>(repeating: 0)
    private var watermarkTarget = SIMD4<Float>(repeating: 0)
    private var watermarkBehindScene = true
    func setWatermark(_ value: SIMD4<Float>, behindScene: Bool, immediate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard watermarkTarget != value || watermarkBehindScene != behindScene else { return }
        watermarkTarget = value
        watermark = value; if !immediate { watermark.w = 0 }
        watermarkBehindScene = behindScene; wake()
    }
    // Hovered card: an extra 0.28 lift that appears over ~200 ms and settles back when the pointer leaves.
    private var hoverCell: Cell?
    private var hoverGain: [Cell: Float] = [:]
    static let lightBackground = SIMD3<Float>(237, 235, 230) / 255
    // Fog offsets from the camera-to-aim distance (browsing / detail); env vars for tuning renders.
    static let fogNearOffset = Float(ProcessInfo.processInfo.environment["RL_FOG_NEAR"] ?? "") ?? -1
    static let fogFarOffset = Float(ProcessInfo.processInfo.environment["RL_FOG_FAR"] ?? "") ?? 12
    static let detailFogNearOffset = Float(ProcessInfo.processInfo.environment["RL_DFOG_NEAR"] ?? "") ?? -1
    static let detailFogFarOffset = Float(ProcessInfo.processInfo.environment["RL_DFOG_FAR"] ?? "") ?? 10
    static var darkBackground: SIMD3<Float> { Experience.music ? SIMD3<Float>(7, 17, 31) / 255 : SIMD3<Float>(0x11, 0x18, 0x1b) / 255 }
    static var darkFog: SIMD3<Float> { Experience.music ? SIMD3<Float>(9, 22, 39) / 255 : SIMD3<Float>(0x26, 0x31, 0x36) / 255 }

    // Selection
    private(set) var selectedIndex = 0
    private var selectedCell = Cell(lane: 2, row: 12)
    private var browseOrigin: SIMD2<Float>?
    private var browseTrack: SIMD2<Float>?
    private var browseSettling = false
    private var browseMomentum: MusicShelfMomentum?
    private var selectionRevision = 0
    private var pendingMomentumSelection = false
    struct BrowseSelection {
        let index: Int
        let cell: Cell
        let revision: Int
    }
    func takeMomentumSelection() -> BrowseSelection? {
        lock.lock(); defer { lock.unlock() }
        guard pendingMomentumSelection else { return nil }
        pendingMomentumSelection = false
        return BrowseSelection(index: selectedIndex, cell: selectedCell, revision: selectionRevision)
    }
    func isCurrent(_ selection: BrowseSelection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return selection.revision == selectionRevision && selection.cell == selectedCell
    }
    var browsePosition: SIMD2<Float> {
        lock.lock(); defer { lock.unlock() }
        return SIMD2(columnCamera.value / Loop.columnSpacing + 2, (-rail.value - 2.17) / Loop.rowSpacing + 15.5)
    }

    /// Project the two shelf tracks into view points, so a drag follows the camera's diagonals.
    /// Adapted from LBEILC/RhineLabUI src/scene.ts (MIT, LICENSE-RhineLabUI).
    func browseProjection(size: SIMD2<Float>) -> (lane: SIMD2<Float>, row: SIMD2<Float>) {
        lock.lock(); defer { lock.unlock() }
        let frame = makeFrame(aspect: size.x / size.y), matrix = frame.proj * frame.view
        let center = selectedPose.position + v3(0, 1.85, 0)
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let clip = matrix * SIMD4(p, 1)
            return SIMD2(clip.x / clip.w, clip.y / clip.w) * size * 0.5
        }
        func track(_ vector: SIMD3<Float>) -> SIMD2<Float> { project(center + vector * 0.5) - project(center - vector * 0.5) }
        return (track(v3(-Loop.columnSpacing, 0, 0)), track(v3(0, 0, -Loop.rowSpacing)))
    }
    @discardableResult func beginBrowse() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let caught = browseMomentum != nil
        browseMomentum = nil; pendingMomentumSelection = false; selectionRevision += 1
        browseOrigin = SIMD2(columnCamera.value, rail.value); browseTrack = browseOrigin
        browseSettling = false; setHover(nil); wake()
        return caught
    }
    func moveBrowse(by cells: SIMD2<Float>) -> (Int, Cell)? {
        lock.lock(); defer { lock.unlock() }
        guard let origin = browseOrigin, !targetDetail else { return nil }
        let track = origin + SIMD2(cells.x * Loop.columnSpacing, -cells.y * Loop.rowSpacing)
        browseTrack = track
        return placeBrowse(at: track)
    }
    private func placeBrowse(at track: SIMD2<Float>) -> (Int, Cell)? {
        columnCamera = Motion.Spring(value: track.x); rail = Motion.Spring(value: track.y)
        lastInteraction = now; wake()
        let cell = Cell(lane: Int((track.x / Loop.columnSpacing + 2).rounded()),
                        row: Int(((-track.y - 2.17) / Loop.rowSpacing + 15.5).rounded()))
        guard cell != selectedCell else { return nil }
        let index = Archive.file(at: cell)
        select(index, navigation: .cell(cell), time: now, preservingBrowse: true)
        return (index, cell)
    }
    func endBrowse(velocity: SIMD2<Float> = .zero) {
        lock.lock(); defer { lock.unlock() }
        guard browseTrack != nil else { return }
        browseMomentum = MusicShelfMomentum(value: browsePosition, velocity: velocity, reduced: reduced)
        browseOrigin = nil; browseTrack = nil; wake()
    }
    func cancelBrowse() {
        lock.lock(); defer { lock.unlock() }
        browseMomentum = nil; browseOrigin = nil; browseTrack = nil; browseSettling = true
        pendingMomentumSelection = false; selectionRevision += 1; wake()
    }
    private func advanceBrowseMomentum(dt: Float) {
        guard var motion = browseMomentum else { return }
        motion.step(dt: dt, reduced: reduced)
        browseMomentum = motion.phase == .idle ? nil : motion
        let track = SIMD2((motion.value.x - 2) * Loop.columnSpacing, -2.17 - (motion.value.y - 15.5) * Loop.rowSpacing)
        if placeBrowse(at: track) != nil { pendingMomentumSelection = true }
    }
    private var returnY: Float?
    private var rotation: Float = 0
    private var targetRotation: Float = 0
    private var inspectionPitch: Float = 0, targetPitch: Float = 0
    private var inspectionZoom: Float = 1, targetZoom: Float = 1
    private var inspectionHeld = false
    private var inspectionInputTime: Double?
    private var inspectionReturning = false
    func beginMusicInspection() {
        lock.lock(); defer { lock.unlock() }
        inspectionHeld = true; inspectionReturning = false; inspectionInputTime = now; wake()
    }
    func endMusicInspection() {
        lock.lock(); defer { lock.unlock() }
        inspectionHeld = false; inspectionInputTime = now; wake()
    }
    var detailRequested: Bool { lock.lock(); defer { lock.unlock() }; return targetDetail }
    var onInspectionChanged: ((Bool) -> Void)?
    func inspect(dx: Float, dy: Float) {
        lock.lock(); defer { lock.unlock() }
        guard canInspect else { return }
        inspectionInputTime = now; inspectionReturning = false
        targetRotation = max(-0.95, min(0.95, targetRotation + dx * 0.0032))
        targetPitch = max(-0.22, min(0.22, targetPitch + dy * 0.0018)); wake()
    }
    func zoomInspection(by magnification: Float) {
        lock.lock(); defer { lock.unlock() }
        guard targetDetail else { return }
        inspectionInputTime = now; inspectionReturning = false
        targetZoom = max(0.92, min(1.18, targetZoom * exp(magnification * 0.55))); wake()
    }
    func resetMusicInspection() {
        lock.lock(); defer { lock.unlock() }
        targetRotation = 0; targetPitch = 0; targetZoom = 1
        inspectionReturning = false; inspectionHeld = false; inspectionInputTime = nil; wake()
    }
    private var selectedPose = CardDraw(position: .zero, tilt: 0, yaw: 0, quality: 0, reveal: 0, labelIndex: 0)

    // Springs
    private var lift = Motion.Spring(value: 0)
    private var rail = Motion.Spring(value: 0)
    private var shoulder = Motion.Spring(value: 12)
    private var laneFocus = Motion.Spring(value: 2)
    private var columnCamera = Motion.Spring(value: 0)
    private var coordinateOrigin = Cell(lane: 0, row: 0)

    // Blends
    private(set) var detail: Float = 0
    private var targetDetail = false
    private var reveal: Float = 0
    var targetReveal: Float = 0
    private var clarity: Float = 0
    private var decryptActive = false
    private var decryptElapsed: Float?
    private var decryptFrame = Decryption.frame(-1)
    private var documentStart: Double?
    private var documentProgress: Float = 1
    private var idleGain: Float = 0
    private var pulseGain: Float = 1
    private var lastInteraction: Double = 0
    private var pulses: [(cell: Cell, time: Double)] = []
    private var pendingPulse: Cell?
    private var clearance: Float = 0
    private var now: Double = 0

    // Camera
    private var camPos = SIMD3<Float>(repeating: 0)
    private var camAim = SIMD3<Float>(-1.091, -0.045, 0.481)
    private var cameraReady = false
    private var cameraDelta: Float = 0
    private var pointer = SIMD2<Float>(0, 0)
    private var fovY: Float = 0.05
    private var nearPlane: Float = 20
    private var farPlane: Float = 260
    private var fogNear: Float = 0
    private var fogFar: Float = 1
    private var focusDistance: Float = 100

    private struct Outgoing {
        var cell: Cell
        var labelIndex: Int
        var lift: Motion.Spring
        var returnY: Float?
        var rotation: Float
        var clarity: Float
        var pose: CardDraw
    }
    private var outgoing: [Outgoing] = []

    var reduced = false
    private var musicPlaying = false
    private var musicGain: Float = 0
    func setMusicPlaying(_ playing: Bool) { lock.lock(); defer { lock.unlock() }; musicPlaying = playing; wake() }
    private var browsingLift: Float { Experience.music ? 0.9 : 0.4 }
    var idleDrift = true
    private(set) var canInspect = false
    var onActivityChanged: ((Bool) -> Void)?

    /// Whether motion is still in progress (the display link must keep running).
    private(set) var isAnimating = true
    /// Only the slow idle drift is running; a low frame rate is enough.
    private(set) var idleOnly = false

    init() {
        for i in 0..<(Loop.columns * Loop.rows) {
            let cell = Loop.poolCell(i)
            cells.append(cell)
            positions.append(cellPosition(cell))
        }
        arrayTilt = Array(repeating: 0, count: cells.count)
        arrayShown = Array(repeating: true, count: cells.count)
        arrayOffsets = positions
        arrayTheme = Array(repeating: 0, count: cells.count)
    }

    func resetCatalogue(selected: Int, time: Double) {
        lock.lock(); defer { lock.unlock() }
        outgoing.removeAll(); pulses.removeAll(); pendingPulse = nil
        selectedIndex = selected
        let location = Archive.location(of: selected)
        selectedCell = Cell(lane: location.lane, row: location.row)
        select(selected, time: time)
    }

    /// Switch the colour theme; the materials follow card by card from the selected file.
    func setTheme(dark: Bool, time: Double, immediate: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        theme.set(dark: dark, time: time, origin: selectedCell, immediate: immediate || reduced)
        wake()
    }

    /// Current background blend (0 light ... 1 dark).
    var themeAmount: Float { lock.lock(); defer { lock.unlock() }; return theme.background(now) }

    // MARK: Layout helpers

    private func cellPosition(_ c: Cell) -> SIMD3<Float> {
        v3(Float(c.lane - 2) * Loop.columnSpacing, -4.6, (Float(c.row) - 15.5) * Loop.rowSpacing)
    }

    // MARK: Selection

    func select(_ index: Int, navigation: ArchiveNavigation? = nil, time: Double, preservingBrowse: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        selectionRevision += 1
        if !preservingBrowse {
            browseOrigin = nil; browseTrack = nil; browseMomentum = nil; browseSettling = false; pendingMomentumSelection = false
        }
        lastInteraction = time
        let cell = Loop.selectionCell(for: index, current: selectedCell, navigation: navigation)
        let changed = cell != selectedCell
        if changed, lift.value > 0.0001 {
            // The old card keeps its height and settles back into its slot on its own.
            outgoing.append(Outgoing(cell: selectedCell, labelIndex: selectedIndex, lift: lift,
                                     returnY: rotation != 0 ? selectedPose.position.y : nil,
                                     rotation: rotation, clarity: clarity, pose: selectedPose))
            lift = Motion.Spring(value: 0)
        }
        selectedIndex = index
        selectedCell = cell
        if changed {
            clarity = 0
            leaveDecryption()
            rotation = 0
            returnY = nil
        }
        // Quickly re-selecting a card that is still settling picks up its motion.
        if let i = outgoing.firstIndex(where: { $0.cell == cell }) {
            let o = outgoing[i]
            lift = o.lift
            rotation = o.rotation
            returnY = o.returnY
            clarity = o.clarity
            outgoing.remove(at: i)
        }
        pendingPulse = cell
        targetRotation = 0; targetPitch = 0; targetZoom = 1
        inspectionHeld = false; inspectionInputTime = nil; inspectionReturning = false
        wake()
    }

    func setDetail(_ on: Bool, time: Double) {
        lock.lock(); defer { lock.unlock() }
        browseOrigin = nil; browseTrack = nil; browseSettling = false
        browseMomentum = nil; pendingMomentumSelection = false; selectionRevision += 1
        targetDetail = on
        if on { pendingPulse = nil; decryptActive = true; decryptElapsed = nil; documentStart = nil; documentProgress = 0 }
        else { leaveDecryption() }
        lastInteraction = time
        if !on { targetRotation = 0 }
        wake()
    }

    func rotate(by delta: Float) {
        lock.lock(); defer { lock.unlock() }
        guard canInspect else { return }
        if Experience.music { inspectionInputTime = now; inspectionReturning = false }
        targetRotation = max(Experience.music ? -0.95 : -0.8, min(Experience.music ? 0.95 : 0.8, targetRotation + delta))
        wake()
    }

    func setPointer(_ p: SIMD2<Float>) { pointer = p }

    func setHover(_ cell: Cell?) {
        lock.lock(); defer { lock.unlock() }
        guard cell != hoverCell else { return }
        hoverCell = cell
        if let cell, hoverGain[cell] == nil { hoverGain[cell] = 0 }
        wake()
    }

    func wake() {
        lock.lock(); defer { lock.unlock() }
        lock.lock(); defer { lock.unlock() }
        if !isAnimating { isAnimating = true; onActivityChanged?(true) }
    }

    // MARK: Per-frame update

    func tick(time: Double, dt rawDt: Double) {
        lock.lock(); defer { lock.unlock() }
        now = time
        let dt = Float(min(rawDt, 0.05))
        watermark.w = lerp(watermark.w, watermarkTarget.w, reduced ? 1 : 1 - exp(-10 * dt))
        if Experience.music && targetDetail && !inspectionHeld, let last = inspectionInputTime, time - last > 0.65 {
            targetRotation = 0; targetPitch = 0; targetZoom = 1
            inspectionReturning = true; inspectionInputTime = nil
        }
        let inspectionBlend = reduced ? 1 : 1 - exp(-(inspectionReturning ? 1.8 : (inspectionHeld ? 30 : 12)) * dt)
        inspectionPitch = lerp(inspectionPitch, targetDetail ? targetPitch : 0, inspectionBlend)
        inspectionZoom = lerp(inspectionZoom, targetDetail ? targetZoom : 1, inspectionBlend)
        musicGain = lerp(musicGain, musicPlaying && !reduced ? 1 : 0, 1 - exp(-dt * 5))
        let blend = 1 - exp(-dt * (reduced ? 35 : 2.8))
        reveal = lerp(reveal, targetReveal, blend)
        rotation = targetDetail ? lerp(rotation, targetRotation, Experience.music ? inspectionBlend : blend)
                                : Motion.returnStep(rotation, dt: dt, reduced: reduced)

        advanceBrowseMomentum(dt: dt)
        coordinatesRebase()
        let chosen = cellPosition(selectedCell)
        let selRow = Float(selectedCell.row), selLane = Float(selectedCell.lane)
        shoulder.damp(to: selRow, rate: reduced ? 35 : (Experience.music && targetDetail ? 9 : 5), dt: dt)
        laneFocus.damp(to: selLane, rate: reduced ? 35 : (Experience.music && targetDetail ? 9 : 4), dt: dt)
        if let track = browseTrack {
            columnCamera = Motion.Spring(value: track.x); rail = Motion.Spring(value: track.y)
        } else if browseMomentum == nil {
            let rate: Float = reduced ? 35 : (Experience.music && (targetDetail || browseSettling) ? 9 : 3.7)
            columnCamera.damp(to: chosen.x, rate: rate, dt: dt)
            rail.damp(to: -2.17 - chosen.z, rate: rate, dt: dt)
            if abs(columnCamera.value - chosen.x) + abs(rail.value + 2.17 + chosen.z) < 0.001 { browseSettling = false }
        }

        let trackX = columnCamera.value
        let centerLane = Double(columnCamera.value / Loop.columnSpacing + 2)
        let centerRow = Double((-rail.value - 2.17) / Loop.rowSpacing + 15.5)
        for i in 0..<positions.count {
            cells[i] = Loop.visibleCell(i, centerLane: centerLane, centerRow: centerRow)
            positions[i] = cellPosition(cells[i])
        }

        pulses.removeAll { time - $0.time >= 3.2 }
        theme.beginFrame()
        // Hover lifts ease in and out; a card that has settled back is forgotten.
        let hoverTarget = (targetDetail || detail > 0.01) ? nil : hoverCell
        for (cell, gain) in hoverGain {
            let goal: Float = cell == hoverTarget ? 1 : 0
            let next = goal > gain ? min(goal, gain + dt / 0.2) : max(goal, gain - dt / 0.2)
            if next <= 0 && goal == 0 { hoverGain[cell] = nil } else { hoverGain[cell] = next }
        }
        let aligningCopy = outgoing.contains { $0.returnY != nil }
        let idle = !reduced && idleDrift && targetReveal > 0 && !targetDetail && detail < 0.01
            && returnY == nil && !aligningCopy && time - lastInteraction > 2.5
        idleGain = lerp(idleGain, idle ? 1 : 0, 1 - exp(-dt * (idle ? 0.8 : 4)))
        pulseGain = lerp(pulseGain, (targetDetail || returnY != nil || aligningCopy) ? 0 : 1, 1 - exp(-dt * 8))

        let musicPhase = Motion.phase(time: time, period: 2 * .pi / 1.4)
        let originRow = Float(coordinateOrigin.row), originLane = Float(coordinateOrigin.lane)
        let shoulderValue = shoulder.value, focus = laneFocus.value
        let activePulses = pulses, gain = pulseGain, iGain = idleGain
        let noPulse = reduced
        func field(_ row: Float, _ lane: Float) -> Float {
            var height: Float = 0
            if musicGain > 0.001 {
                height += 0.13 * sin(musicPhase - (row - selRow) * 0.7) * exp(-abs(row - selRow) * 0.24) * musicGain * (1 - detail)
            }
            if iGain > 0.001 { height += Motion.idleWave(row: row + originRow, lane: lane + originLane, time: time) * iGain }
            if !noPulse, gain > 0.001 {
                var ripple: Float = 0
                for p in activePulses {
                    let d = hypot(row - Float(p.cell.row), (lane - Float(p.cell.lane)) * 2.2)
                    ripple += Motion.selectionWave(distance: d, age: Float(time - p.time))
                }
                height += max(-0.6, min(0.6, ripple)) * gain
            }
            return height + Motion.settlingWave(distance: row - shoulderValue)
                * Motion.columnStrength(lane: lane, focus: focus)
        }

        let selectedBase = chosen.y + field(selRow, selLane)
        if let held = returnY, rotation != 0 {
            lift.value = held - selectedBase
            lift.velocity = 0
        } else {
            returnY = nil
            let nearOld = outgoing.contains { $0.returnY != nil && $0.cell.lane == selectedCell.lane && abs($0.cell.row - selectedCell.row) < 5 }
            let target: Float = targetDetail ? Motion.inspectionLift : (nearOld ? 0 : browsingLift * targetReveal)
            lift.damp(to: target, rate: reduced ? 35 : (Experience.music && targetDetail ? 8 : 4.2), dt: dt)
        }

        let cameraTarget: Float = Experience.music ? (targetDetail ? 1 : 0) : (targetDetail ? ease((lift.value - 0.8) / 2.4)
            : (returnY != nil ? detail : ease((lift.value - browsingLift) / (Motion.inspectionLift - browsingLift))))
        detail = lerp(detail, cameraTarget, 1 - exp(-dt * (reduced ? 35 : (Experience.music ? 6 : 2.8))))

        updateDecryption(dt: dt, time: time, ready: targetDetail && detail > 0.78 && lift.value > 3.3)

        let entryZ = -28 * (1 - reveal)
        let railZ = rail.value

        // Cards that have been replaced settle back down.
        for i in stride(from: outgoing.count - 1, through: 0, by: -1) {
            var o = outgoing[i]
            let p = cellPosition(o.cell)
            let baseY = p.y + field(Float(o.cell.row), Float(o.cell.lane))
            o.rotation = Motion.returnStep(o.rotation, dt: dt, reduced: reduced)
            if let held = o.returnY {
                o.lift.value = held - baseY
                o.lift.velocity = 0
                if o.rotation == 0 { o.returnY = nil }
            } else {
                o.lift.damp(to: 0, rate: reduced ? 35 : (Experience.music && targetDetail ? 9 : 4.5), dt: dt)
            }
            o.clarity = reduced ? 0 : o.clarity * exp(-dt * 9)
            let q = ease(o.lift.value / 0.4)
            let slope = field(Float(o.cell.row) + 0.5, Float(o.cell.lane)) - field(Float(o.cell.row) - 0.5, Float(o.cell.lane))
            o.pose = CardDraw(position: v3(p.x - trackX, baseY + o.lift.value, p.z + entryZ + railZ),
                              tilt: slope * 0.024 * (1 - detail) * (1 - q), yaw: o.rotation,
                              quality: q, reveal: o.clarity, labelIndex: o.labelIndex,
                              theme: theme.sample(o.cell, time))
            if o.lift.value < 0.0001, abs(o.rotation) < 0.0001 {
                outgoing.remove(at: i)
            } else {
                outgoing[i] = o
            }
        }

        // The selection ripple starts once the new card has risen and old ones have dropped below it.
        if let pending = pendingPulse, !targetDetail, targetReveal > 0 {
            let selectedY = selectedBase + lift.value
            let oldLower = outgoing.allSatisfy {
                $0.cell.lane != selectedCell.lane || abs($0.cell.row - selectedCell.row) > 4
                    || $0.pose.position.y + 0.015 < selectedY
            }
            if lift.value >= 0.35, returnY == nil, oldLower {
                if !reduced { pulses.append((pending, time)); pulses = Array(pulses.suffix(6)) }
                pendingPulse = nil
            }
        }

        var hidden = Set(outgoing.map(\.cell))
        hidden.insert(selectedCell)
        for i in 0..<cells.count {
            let c = cells[i], p = positions[i]
            let slope = field(Float(c.row) + 0.5, Float(c.lane)) - field(Float(c.row) - 0.5, Float(c.lane))
            arrayShown[i] = !hidden.contains(c)
            let hover = hoverGain[c].map { 0.28 * Motion.smooth($0) } ?? 0
            arrayOffsets[i] = v3(p.x - trackX, p.y + field(Float(c.row), Float(c.lane)) + hover, p.z + entryZ + railZ)
            arrayTilt[i] = slope * 0.024 * (1 - detail)
            arrayTheme[i] = arrayShown[i] ? theme.sample(c, time) : theme.target
        }
        let selSlope = field(selRow + 0.5, selLane) - field(selRow - 0.5, selLane)
        let q = ease(lift.value / 0.4)
        selectedPose = CardDraw(position: v3(chosen.x - trackX, selectedBase + lift.value, chosen.z + entryZ + railZ),
                                tilt: selSlope * 0.024 * (1 - detail) * (1 - q) + (Experience.music ? inspectionPitch * detail : 0), yaw: rotation,
                                quality: q, reveal: clarity, labelIndex: selectedIndex,
                                theme: theme.sample(selectedCell, time))

        updateCamera(dt: dt)

        // Neighbour clearance decides when a card may be dragged around.
        var neighborTop = -Float.infinity
        for r in (selectedCell.row - 5)...(selectedCell.row + 5) where r != selectedCell.row {
            neighborTop = max(neighborTop, -4.6 + field(Float(r), selLane) + (Experience.music ? 3.525 : 3.76))
        }
        for o in outgoing where o.cell.lane == selectedCell.lane && abs(o.cell.row - selectedCell.row) <= 5 {
            neighborTop = max(neighborTop, o.pose.position.y + (Experience.music ? 3.525 : 3.76))
        }
        clearance = selectedPose.position.y - neighborTop
        let inspectReady = targetDetail && detail > 0.9 && pulseGain < 0.01 && clearance > 0.3
        if canInspect != inspectReady { canInspect = inspectReady; onInspectionChanged?(inspectReady) }

        updateActivity(idle: idle, chosen: chosen)
    }

    private func leaveDecryption() {
        decryptActive = false
        decryptElapsed = nil
        decryptFrame = Decryption.frame(-1)
        documentStart = nil
        documentProgress = 1
    }

    /// Drives the glass-clearing sweep, the scan lines and the text redaction from one clock.
    private func updateDecryption(dt: Float, time: Double, ready: Bool) {
        if Experience.music {
            decryptActive = false; decryptElapsed = nil; documentProgress = 1
            clarity = lerp(clarity, targetDetail ? 1 : 0, reduced ? 1 : 1 - exp(-7 * dt))
            if abs(clarity - (targetDetail ? 1 : 0)) < 0.0005 { clarity = targetDetail ? 1 : 0 }
            return
        }
        if !decryptActive {
            clarity = reduced ? 0 : clarity * exp(-dt * 9)
            if clarity < 0.0001 { clarity = 0 }
            decryptFrame = Decryption.frame(-1)
            return
        }
        if reduced {
            decryptElapsed = Decryption.duration
            decryptFrame = Decryption.frame(Decryption.end)
            clarity = 1
            documentProgress = 1
            return
        }
        if decryptElapsed == nil, ready { decryptElapsed = 0 }
        else if let e = decryptElapsed { decryptElapsed = min(e + dt, Decryption.duration) }
        if let e = decryptElapsed {
            decryptFrame = Decryption.frame(Decryption.start + e * Decryption.rate)
            clarity = decryptFrame.clarity > clarity ? decryptFrame.clarity
                : (decryptFrame.phase == .clear ? 1 : clarity * exp(-dt * 9))
        }
        // The text starts opening with the glass; its easing tail lasts a little longer.
        if documentStart == nil, decryptFrame.clarity > 0 { documentStart = time }
        if let started = documentStart { documentProgress = Float(min(1, max(0, (time - started) / 0.95))) }
    }

    /// Keep logical coordinates small over very long sessions.
    private func coordinatesRebase() {
        guard browseTrack == nil && browseMomentum == nil else { return }
        let period = max(1, Archive.columns.count)
        let lane = abs(selectedCell.lane) > 2048 ? Int((Double(selectedCell.lane - 2) / Double(period)).rounded()) * period : 0
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let rowPeriod = Archive.columns.indices.reduce(1) { value, lane in
            let n = max(1, Archive.columnFiles(lane).count)
            return min(1_000_000, value / gcd(value, n) * n)
        }
        let row = abs(selectedCell.row) > max(2048, rowPeriod * 2) ? Int(floor(Double(selectedCell.row - 12) / Double(rowPeriod))) * rowPeriod : 0
        if lane == 0 && row == 0 { return }
        selectedCell.lane -= lane; selectedCell.row -= row
        coordinateOrigin.lane += lane; coordinateOrigin.row += row
        laneFocus.value -= Float(lane); shoulder.value -= Float(row)
        columnCamera.value -= Float(lane) * Loop.columnSpacing; rail.value += Float(row) * Loop.rowSpacing
        for i in outgoing.indices { outgoing[i].cell.lane -= lane; outgoing[i].cell.row -= row }
        for i in pulses.indices { pulses[i].cell.lane -= lane; pulses[i].cell.row -= row }
        if pendingPulse != nil { pendingPulse!.lane -= lane; pendingPulse!.row -= row }
    }

    // MARK: Camera

    private func updateCamera(dt: Float) {
        let yaw: Float = 59 * .pi / 180, elevation: Float = 19 * .pi / 180
        let d = detail
        let span = lerp(9.2, Experience.music ? 6.7 : 5.9, d) / (Experience.music ? lerp(1, inspectionZoom, d) : 1)
        let distance = lerp(140, 72, d)
        let arrayAim = v3(-1.091, -0.045, 0.481)
        var dir = v3(-sin(yaw) * cos(elevation), sin(elevation), cos(yaw) * cos(elevation))
        dir = simd_normalize(simd_mix(dir, Experience.music ? v3(-0.131, 0.342, 0.931) : v3(-0.277, 0.238, 0.931), SIMD3(repeating: d)))
        let right = simd_normalize(simd_cross(v3(0, 1, 0), dir))
        let up = simd_normalize(simd_cross(dir, right))
        let pixelScale = 1080 / span
        let modelPos = selectedPose.position
        // The extracted card sits left of centre; the reading panel takes the right.
        let slot = Experience.music ? v3(0, -4.6 + Motion.settlingWave(distance: 0) + Motion.inspectionLift, -2.17) : modelPos
        let detailAim = slot + v3(0, 1.85, 0) + right * ((960 - (Experience.music ? 490 : 550)) / pixelScale) + up * ((560 - 540) / pixelScale)
        let aim = simd_mix(arrayAim, detailAim, SIMD3(repeating: d))
        var position = aim + dir * distance
        if !reduced { position.x += pointer.x * 0.12; position.y -= pointer.y * 0.12 }

        let blend: Float = cameraReady ? 1 - exp(-dt * 5) : 1
        cameraReady = true
        cameraDelta = simd_distance(camPos, position) + simd_distance(camAim, aim)
        camPos = simd_mix(camPos, position, SIMD3(repeating: blend))
        camAim = simd_mix(camAim, aim, SIMD3(repeating: blend))

        let renderedDistance = simd_distance(camPos, camAim)
        fovY = 2 * atan(span / (2 * distance))
        // The dark mist starts closer and ends sooner while browsing (web: +1 / +16 against +5 / +25).
        let th = theme.background(now)
        fogNear = renderedDistance + lerp(lerp(Self.fogNearOffset, 1, th), Self.detailFogNearOffset, d)
        fogFar = renderedDistance + lerp(lerp(Self.fogFarOffset, 16, th), Self.detailFogFarOffset, d)
        nearPlane = max(5, renderedDistance - 50)
        farPlane = renderedDistance + 60
        focusDistance = simd_distance(camPos, modelPos + v3(0, 2, 0))
    }

    // MARK: Frame output

    func makeFrame(aspect: Float) -> RenderFrame {
        lock.lock(); defer { lock.unlock() }
        var f = RenderFrame()
        f.view = Matrix.lookAt(eye: camPos, target: camAim, up: v3(0, 1, 0))
        f.proj = Matrix.perspective(fovY: fovY, aspect: aspect, near: nearPlane, far: farPlane)
        f.cameraPosition = camPos
        f.fogNear = fogNear
        f.fogFar = fogFar
        f.focusDistance = focusDistance
        f.depthOfField = Experience.music ? 0 : 1
        f.near = nearPlane
        f.far = farPlane
        f.detail = detail
        f.time = Float(now)
        f.watermark = watermark; f.watermarkBehindScene = watermarkBehindScene
        let th = theme.background(now)
        f.themeAmount = th
        f.background = simd_mix(Self.lightBackground, Self.darkBackground, SIMD3(repeating: th))
        f.fogColor = simd_mix(Self.lightBackground, Self.darkFog, SIMD3(repeating: th))
        // Cull cards that cannot contribute: outside the view, or fully fogged away.
        let viewProj = f.proj * f.view
        let corners: [SIMD3<Float>] = [
            v3(-2.5, 0, -0.13), v3(2.5, 0, -0.13), v3(-2.5, 3.7, -0.13), v3(2.5, 3.7, -0.13),
            v3(-2.5, 0, 0.26), v3(2.5, 0, 0.26), v3(-2.5, 3.7, 0.26), v3(2.5, 3.7, 0.26)]
        for i in 0..<arrayOffsets.count where arrayShown[i] {
            let p = arrayOffsets[i]
            var outside = [Bool](repeating: true, count: 6)
            var nearestDepth = Float.infinity
            for c in corners {
                let clip = viewProj * SIMD4(p + c, 1)
                let w = clip.w
                if clip.x >= -w { outside[0] = false }
                if clip.x <= w { outside[1] = false }
                if clip.y >= -w { outside[2] = false }
                if clip.y <= w { outside[3] = false }
                if clip.z >= 0 { outside[4] = false }
                if clip.z <= w { outside[5] = false }
                nearestDepth = min(nearestDepth, w)
            }
            if outside.contains(true) || nearestDepth > fogFar { continue }
            f.arrayCards.append(SIMD4(p.x, p.y, p.z, arrayTilt[i]))
            f.arrayTheme.append(arrayTheme[i])
            if Experience.music { f.arrayLabels.append(Archive.file(at: cells[i])) }
            if Experience.music {
                let index = Archive.file(at: cells[i])
                if MusicArtwork.image(index) != nil {
                    f.arrayPrints.append(CardDraw(position: p, tilt: arrayTilt[i], yaw: 0, quality: 0.85, reveal: 0, labelIndex: index, theme: arrayTheme[i]))
                }
            }
        }
        f.cards = [selectedPose] + outgoing.map(\.pose)
        return f
    }

    // MARK: Interface overlay

    /// 0 while the text is redacted, 1 once fully readable.
    var redactionProgress: Float { lock.lock(); defer { lock.unlock() }; return decryptActive ? documentProgress : 1 }

    /// Scan lines, corner marks and redaction progress for the current frame.
    func overlay(aspect: Float) -> Decryption.Overlay {
        lock.lock(); defer { lock.unlock() }
        var o = Decryption.Overlay()
        o.frame = decryptFrame
        o.active = decryptActive
        o.documentProgress = decryptActive ? documentProgress : 1
        guard decryptActive else { return o }
        let view = Matrix.lookAt(eye: camPos, target: camAim, up: v3(0, 1, 0))
        let viewProj = Matrix.perspective(fovY: fovY, aspect: aspect, near: nearPlane, far: farPlane) * view
        let r = Matrix.rotationXY(tilt: selectedPose.tilt, yaw: selectedPose.yaw)
        func project(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let world = selectedPose.position + r * v3(p.x, p.y, 0.255)
            let c = viewProj * SIMD4(world, 1)
            return SIMD2(c.x / c.w, c.y / c.w)
        }
        func point(_ t: Float) -> SIMD2<Float> { Decryption.scanFrom + (Decryption.scanTo - Decryption.scanFrom) * t }
        o.segments = decryptFrame.intervals.map { (project(point($0.0)), project(point($0.1))) }
        o.corners = Decryption.corners.map(project)
        o.center = project(point(0.5))
        return o
    }

    // MARK: Picking

    /// Closest card under a point given in normalised device coordinates (-1...1, y up).
    func pick(ndc: SIMD2<Float>, aspect: Float) -> (index: Int, cell: Cell)? {
        lock.lock(); defer { lock.unlock() }
        let view = Matrix.lookAt(eye: camPos, target: camAim, up: v3(0, 1, 0))
        let invView = simd_inverse(view)
        let t = tan(fovY / 2)
        let dirView = simd_normalize(v3(ndc.x * t * aspect, ndc.y * t, -1))
        let origin = camPos
        let world = invView * SIMD4(dirView, 0)
        let dir = simd_normalize(v3(world.x, world.y, world.z))

        func hit(position: SIMD3<Float>, tilt: Float, yaw: Float) -> Float? {
            // Slab test in the card's local space.
            let inv = Matrix.rotationXY(tilt: tilt, yaw: yaw).transpose
            let o = inv * (origin - position), d = inv * dir
            var tMin: Float = 0, tMax = Float.infinity
            let lo = v3(-2.5, 0, -0.13), hi = v3(2.5, 3.7, 0.26)
            for axis in 0..<3 {
                if abs(d[axis]) < 1e-6 {
                    if o[axis] < lo[axis] || o[axis] > hi[axis] { return nil }
                } else {
                    var t0 = (lo[axis] - o[axis]) / d[axis], t1 = (hi[axis] - o[axis]) / d[axis]
                    if t0 > t1 { swap(&t0, &t1) }
                    tMin = max(tMin, t0); tMax = min(tMax, t1)
                    if tMin > tMax { return nil }
                }
            }
            return tMin
        }

        var best: (t: Float, index: Int, cell: Cell)?
        if let t = hit(position: selectedPose.position, tilt: selectedPose.tilt, yaw: selectedPose.yaw) {
            best = (t, selectedIndex, selectedCell)
        }
        for i in 0..<cells.count where arrayShown[i] {
            if let t = hit(position: arrayOffsets[i], tilt: arrayTilt[i], yaw: 0), t < (best?.t ?? .infinity) {
                best = (t, Archive.file(at: cells[i]), cells[i])
            }
        }
        return best.map { ($0.index, $0.cell) }
    }

    // MARK: Activity tracking

    /// Why the loop is still running (diagnostics).
    private(set) var activityReason = ""

    private func updateActivity(idle: Bool, chosen: SIMD3<Float>) {
        var why: [String] = []
        if browseTrack != nil { why.append("browse") }
        if browseMomentum != nil { why.append("inertia") }
        if abs(watermark.w - watermarkTarget.w) > 0.0001 { why.append("watermark") }
        let springs = [("lift", lift), ("rail", rail), ("shoulder", shoulder), ("laneFocus", laneFocus), ("columnCamera", columnCamera)]
        for (name, spring) in springs where abs(spring.velocity) > 0.0005 { why.append("v:" + name) }
        if abs(reveal - targetReveal) > 0.0005 { why.append("reveal") }
        if abs(detail - (targetDetail ? 1 : 0)) > 0.0005 { why.append("detail") }
        if !pulses.isEmpty { why.append("pulses") }
        if pendingPulse != nil && !targetDetail { why.append("pendingPulse") }
        if !outgoing.isEmpty { why.append("outgoing") }
        if returnY != nil { why.append("returnY") }
        if decryptActive && (decryptElapsed == nil || decryptElapsed! < Decryption.duration || documentProgress < 1) { why.append("decrypt") }
        if !targetDetail && clarity > 0.001 { why.append("clarity↓") }
        if abs(inspectionPitch - (targetDetail ? targetPitch : 0)) > 0.0005 || abs(inspectionZoom - (targetDetail ? targetZoom : 1)) > 0.0005 { why.append("inspection") }
        if abs(rotation - targetRotation) > 0.0005 { why.append("rotation") }
        if Experience.music && targetDetail && !inspectionHeld && inspectionInputTime != nil { why.append("returnDelay") }
        if cameraDelta > 0.01 { why.append("camera") }
        if theme.active(at: now) { why.append("theme") }
        if hoverGain.contains(where: { $0.value > 0 && $0.value < 1 }) || (hoverCell != nil && hoverGain.values.contains { $0 < 1 }) { why.append("hover") }
        let liftTarget: Float = targetDetail ? Motion.inspectionLift : browsingLift * targetReveal
        if abs(lift.value - liftTarget) > 0.001 { why.append("liftTarget") }
        if abs(columnCamera.value - chosen.x) > 0.001 { why.append("column") }
        if abs(rail.value + 2.17 + chosen.z) > 0.001 { why.append("railTarget") }
        if abs(shoulder.value - Float(selectedCell.row)) > 0.001 { why.append("shoulderTarget") }
        activityReason = why.joined(separator: ",")
        let moving = !why.isEmpty
        let drifting = idleGain > 0.002 || idle || musicGain > 0.002 || (musicPlaying && !reduced)
        idleOnly = !moving && drifting
        let next = moving || drifting
        if next != isAnimating { isAnimating = next; onActivityChanged?(next) }
    }
}

/// A material wave with a frozen origin and an interruptible per-card starting colour
/// (web `theme-motion.ts`): rows lag 34 ms, lanes 110 ms, at most 600 ms; a card takes 580 ms,
/// the background 850 ms.
struct ThemeWave {
    private(set) var target: Float = 0
    private var start: Double = -10
    private var origin = Cell(lane: 2, row: 12)
    private var from: [Cell: Float] = [:]
    private var latest: [Cell: Float] = [:]
    private var backgroundFrom: Float = 0

    private static func ease(_ t: Double) -> Float {
        let t = Float(max(0, min(1, t)))
        return t * t * (3 - 2 * t)
    }

    mutating func set(dark: Bool, time: Double, origin: Cell, immediate: Bool = false) {
        let target: Float = dark ? 1 : 0
        if target == self.target && !immediate { return }
        backgroundFrom = immediate ? target : background(time)
        from = immediate ? [:] : latest
        self.target = target
        start = immediate ? time - 10 : time
        self.origin = origin
    }

    func background(_ time: Double) -> Float {
        backgroundFrom + (target - backgroundFrom) * Self.ease((time - start) / 0.85)
    }

    func active(at time: Double) -> Bool { time - start < 0.85 + 0.6 + 0.58 }

    mutating func beginFrame() { latest.removeAll(keepingCapacity: true) }

    mutating func sample(_ cell: Cell, _ time: Double) -> Float {
        let delay = min(0.6, Double(abs(cell.row - origin.row)) * 0.034 + Double(abs(cell.lane - origin.lane)) * 0.11)
        let base = from[cell] ?? backgroundFrom
        let value = base + (target - base) * Self.ease((time - start - delay) / 0.58)
        latest[cell] = value
        return value
    }
}
