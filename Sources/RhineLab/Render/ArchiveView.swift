import AppKit
import SwiftUI
import QuartzCore
import Metal

/// Metal-backed view. Simulation and drawing run on their own thread, paced by CAMetalDisplayLink,
/// so a busy main thread (SwiftUI layout, input) can never stall a frame.
final class ArchiveView: NSView, CAMetalDisplayLinkDelegate {
    let engine: ArchiveEngine
    let viewer: ViewerEngine
    let renderer: MetalRenderer
    var onHover: ((Int?) -> Void)?
    var onSelect: ((Int, Cell) -> Void)?
    /// Wheel over the array: +1 next file, −1 previous.
    var onStep: ((Int) -> Void)?
    var canPick: () -> Bool = { true }
    private var wheelAccumulated: CGFloat = 0

    /// Resolution multiplier (relative to points, capped by the screen's backing scale) while still,
    /// and while moving: motion trades a little sharpness for a steady 120 fps.
    var stillScale: CGFloat = 1.5
    var motionScale: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["RL_MOTION_SCALE"] ?? "") ?? 1.25)
    private var pixelBudget = RenderQuality.pixelBudget
    private var settleFrames = 0

    /// Pixel size of the last drawable (main thread), for the settings summary.
    var renderedSize: CGSize { metalLayer.drawableSize }

    /// Resolution and renderer settings from the quality preferences.
    func applyQuality(_ q: RenderQuality, superPerformance: Bool) {
        let scale = CGFloat(q.pixelRatio) * CGFloat(q.scale) / 100
        stillScale = scale
        motionScale = max(0.5, scale * 0.75)
        pixelBudget = superPerformance ? RenderQuality.superPixelBudget : RenderQuality.pixelBudget
        renderer.renderQuality = q
        updateDrawableSize()
    }

    // Adaptive quality: the GPU is shared with other apps, so watch the real frame cost and
    // step effects down (and the frame rate to 60) rather than letting frames slip.
    private var level = 0
    private var overBudget = 0, underBudget = 0
    private static let motionScales: [CGFloat] = [1.5, 1.25, 1.0, 1.0]
    private static let effectsOff = [0, 2, 6, 6]    // bit 2 = AO, bit 4 = depth of field

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var link: CAMetalDisplayLink?
    private var renderThread: Thread?
    private var lastTimestamp: CFTimeInterval = 0
    private var wasIdleRate = false
    private let stats = FrameStats()
    private var downPoint = CGPoint.zero
    private enum Drag { case none, inspect, orbit, pan }
    private var drag = Drag.none

    /// Whichever simulation is on screen.
    private var animating: Bool { viewer.isOpen ? viewer.isAnimating : engine.isAnimating }

    init(engine: ArchiveEngine, viewer: ViewerEngine, renderer: MetalRenderer) {
        self.engine = engine
        self.viewer = viewer
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        let activity: (Bool) -> Void = { [weak self] active in
            guard let self else { return }
            if active {
                self.lastTimestamp = 0
                self.settleFrames = 0
                self.link?.isPaused = false
            } else {
                // Keep the link alive for a few more frames so the final, sharp frame gets drawn.
                self.settleFrames = 3
            }
        }
        engine.onActivityChanged = activity
        viewer.onActivityChanged = activity
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        guard window != nil, link == nil else { return }
        let l = CAMetalDisplayLink(metalLayer: metalLayer)
        l.delegate = self
        l.preferredFrameLatency = 2
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link = l
        let thread = Thread { [weak self] in
            guard let self, let l = self.link else { return }
            l.add(to: .current, forMode: .common)
            RunLoop.current.run()
        }
        thread.name = "RhineLab.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        renderThread = thread
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    // View geometry is copied here on the main thread so the render thread never touches AppKit.
    private var points = CGSize.zero
    private var backing: CGFloat = 2

    private func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        points = bounds.size
        backing = window?.backingScaleFactor ?? 2
        applyScale(animating ? motionScale : stillScale)
        engine.wake()
        if viewer.isOpen { viewer.wake() }
    }

    private func applyScale(_ requested: CGFloat) {
        var scale = min(requested, backing)
        let pixels = points.width * points.height * scale * scale
        if pixels > CGFloat(pixelBudget) { scale *= (CGFloat(pixelBudget) / pixels).squareRoot() }
        let size = CGSize(width: (points.width * scale).rounded(), height: (points.height * scale).rounded())
        if size.width > 0, metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    // MARK: Frame loop (render thread)

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let now = update.targetTimestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : now - lastTimestamp
        lastTimestamp = now
        let cpuStart = CACurrentMediaTime()
        let viewerOpen = viewer.isOpen
        if viewerOpen { viewer.tick(time: now, dt: dt) } else { engine.tick(time: now, dt: dt) }
        let tickEnd = CACurrentMediaTime()
        let animating = self.animating
        let idle = !viewerOpen && engine.idleOnly
        if idle != wasIdleRate {
            wasIdleRate = idle
            link.preferredFrameRateRange = idle
                ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
                : (level >= 3 ? CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60) : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120))
        }
        // Choose the resolution for the *next* frame: modest while moving, full once still.
        let moving = animating && !idle
        if moving { applyScale(min(motionScale, Self.motionScales[level])) } else { applyScale(stillScale) }
        if !animating {
            settleFrames -= 1
            if settleFrames <= 0 { link.isPaused = true }
        }
        let drawable = update.drawable
        let aspect = Float(drawable.texture.width) / Float(drawable.texture.height)
        var frame = viewerOpen ? viewer.makeFrame(aspect: aspect) : engine.makeFrame(aspect: aspect)
        frame.effectsOff |= moving ? Self.effectsOff[level] : 0
        renderer.render(frame, to: drawable.texture, present: drawable)
        if moving { adapt(link) }
        stats.reason = (viewerOpen ? "viewer" : engine.activityReason) + " | lvl " + String(level)
        stats.record(interval: dt, tick: tickEnd - cpuStart, encode: CACurrentMediaTime() - tickEnd, gpu: renderer)
    }

    /// Escalate when frames cost more than the refresh budget; relax after a long calm stretch.
    private func adapt(_ link: CAMetalDisplayLink) {
        let budget = level >= 3 ? 16.0 : 7.6
        let gpu = renderer.smoothedGPUms
        if gpu > budget { overBudget += 1; underBudget = 0 } else if gpu < budget * 0.5 { underBudget += 1; overBudget = 0 } else { overBudget = 0; underBudget = 0 }
        if overBudget > 20 && level < 3 {
            level += 1; overBudget = 0
            if level == 3 { link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60) }
        } else if underBudget > 240 && level > 0 {
            level -= 1; underBudget = 0
            if level < 3 { link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120) }
        }
    }

    override var acceptsFirstResponder: Bool { false }

    // MARK: Pointer

    private func card(at p: CGPoint) -> (Int, Cell)? {
        let ndc = SIMD2<Float>(Float(p.x / bounds.width * 2 - 1), Float(p.y / bounds.height * 2 - 1))
        return engine.pick(ndc: ndc, aspect: Float(bounds.width / bounds.height))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !viewer.isOpen else { return }
        let p = convert(event.locationInWindow, from: nil)
        engine.setPointer(SIMD2(Float(p.x / bounds.width - 0.5), Float(0.5 - p.y / bounds.height)))
        engine.wake()
        let hit = canPick() ? card(at: p) : nil
        engine.setHover(hit?.1)
        onHover?(hit?.0)
    }

    override func mouseExited(with event: NSEvent) {
        engine.setPointer(.zero)
        engine.setHover(nil)
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        if viewer.isOpen { drag = event.modifierFlags.contains(.option) ? .pan : .orbit; return }
        drag = engine.canInspect ? .inspect : .none
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = Float(event.deltaX), dy = Float(event.deltaY), h = Float(bounds.height)
        switch drag {
        case .inspect: engine.rotate(by: dx * 0.004)
        case .orbit: viewer.orbit(dx: dx, dy: dy, viewHeight: h)
        case .pan: viewer.pan(dx: dx, dy: dy, viewHeight: h)
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        guard !viewer.isOpen else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) < 6, canPick(), let (index, cell) = card(at: p) else { return }
        onSelect?(index, cell)
    }

    override func rightMouseDown(with event: NSEvent) { if viewer.isOpen { drag = .pan } }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { drag = .none }

    override func scrollWheel(with event: NSEvent) {
        if viewer.isOpen {
            viewer.dolly(scrollDelta: Float(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
            return
        }
        guard canPick() else { return }
        // A notch (or ~40 pt of trackpad travel) steps one file: down is the next one.
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began { wheelAccumulated = 0 }
            wheelAccumulated += event.scrollingDeltaY
            if abs(wheelAccumulated) >= 40 {
                onStep?(wheelAccumulated > 0 ? 1 : -1)
                wheelAccumulated = 0
            }
        } else if event.scrollingDeltaY != 0 {
            onStep?(event.scrollingDeltaY > 0 ? 1 : -1)
        }
    }
}

struct ArchiveSceneView: NSViewRepresentable {
    let view: ArchiveView
    func makeNSView(context: Context) -> ArchiveView { view }
    func updateNSView(_ nsView: ArchiveView, context: Context) {}
}

/// Frame pacing diagnostics, enabled with RL_STATS=1.
final class FrameStats {
    private let enabled = ProcessInfo.processInfo.environment["RL_STATS"] != nil
    private var intervals: [Double] = [], ticks: [Double] = [], encodes: [Double] = []
    private var lastReport = CACurrentMediaTime()
    var reason = ""

    func record(interval: Double, tick: Double, encode: Double, gpu: MetalRenderer) {
        guard enabled else { return }
        intervals.append(interval * 1000); ticks.append(tick * 1000); encodes.append(encode * 1000)
        let now = CACurrentMediaTime()
        if now - lastReport > 2 {
            lastReport = now
            func q(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * p))] }
            let late = intervals.filter { $0 > 1.5 * q(intervals, 0.5) }.count
            let g = gpu.drainGPUTimes()
            print(String(format: "frames %d | interval %.1f/%.1f/%.1f ms (p50/p95/max), %d late | cpu tick %.2f encode+wait %.2f | gpu %.1f/%.1f/%.1f ms",
                         intervals.count, q(intervals, 0.5), q(intervals, 0.95), intervals.max() ?? 0, late,
                         ticks.reduce(0, +) / Double(max(1, ticks.count)), encodes.reduce(0, +) / Double(max(1, encodes.count)),
                         q(g, 0.5), q(g, 0.95), g.max() ?? 0) + " | " + reason)
            fflush(stdout)
            intervals = []; ticks = []; encodes = []
        }
    }
}
