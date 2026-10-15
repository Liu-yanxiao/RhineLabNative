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
    var onOpen: (() -> Void)?
    /// Wheel over the array: +1 next file, −1 previous.
    var onStep: ((Int) -> Void)?
    var onStepColumn: ((Int) -> Void)?
    var canPick: () -> Bool = { true }
    func wakeForSceneChange() { lastTimestamp = 0; settleFrames = 3; link?.isPaused = false }
    private struct ArtworkRequest: Equatable { let index: Int; let url: URL; let high: Bool }
    private var artworkTasks: [Int: Task<Void, Never>] = [:]
    private var artworkTickets: [Int: UUID] = [:]
    private var runningArtwork: [Int: ArtworkRequest] = [:]
    private var pendingArtwork: [ArtworkRequest] = []
    private var artworkRevision = 0
    func clearMusicArtwork() {
        artworkRevision += 1
        artworkTasks.values.forEach { $0.cancel() }; artworkTasks.removeAll(); artworkTickets.removeAll()
        runningArtwork.removeAll(); pendingArtwork.removeAll(); MusicArtwork.clear()
    }
    func prepareMusicArtwork(selected: Int, urls: [Int: URL], high: Bool = false) {
        if let old = MusicArtwork.setHero(high ? selected : nil) { renderer.invalidateLabel(old) }
        let order = [selected] + urls.keys.filter { $0 != selected }.sorted { abs($0 - selected) < abs($1 - selected) }
        let requests = order.compactMap { index in urls[index].map { ArtworkRequest(index: index, url: $0, high: high && index == selected) } }
        for index in Array(runningArtwork.keys) where !requests.contains(runningArtwork[index]!) {
            artworkTasks.removeValue(forKey: index)?.cancel(); artworkTickets[index] = nil; runningArtwork[index] = nil
        }
        pendingArtwork = []
        for request in requests {
            if let image = MusicArtwork.cached(request.url, high: request.high) {
                let old = MusicArtwork.image(request.index)
                MusicArtwork.store(image, index: request.index, high: request.high)
                if old !== MusicArtwork.image(request.index) { renderer.invalidateLabel(request.index) }
            } else if runningArtwork[request.index] == nil { pendingArtwork.append(request) }
        }
        pumpArtwork(); wakeForSceneChange()
    }
    private func pumpArtwork() {
        while artworkTasks.count < 3, !pendingArtwork.isEmpty {
            let request = pendingArtwork.removeFirst(), revision = artworkRevision, ticket = UUID()
            artworkTickets[request.index] = ticket; runningArtwork[request.index] = request
            artworkTasks[request.index] = Task { [weak self] in
                do {
                    let (data, response) = try await URLSession.shared.data(from: request.url)
                    try Task.checkCancellation()
                    guard data.count < 12_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else { throw MusicFailure.message("封面暂不可用") }
                    let decoded = await Task.detached(priority: .utility) {
                        (MusicArtwork.thumbnail(data), request.high ? MusicArtwork.thumbnail(data, maxPixelSize: 1536) : nil)
                    }.value
                    try Task.checkCancellation()
                    guard let self, self.artworkRevision == revision, self.artworkTickets[request.index] == ticket, let gallery = decoded.0 else { return }
                    MusicArtwork.cache(gallery, url: request.url); MusicArtwork.store(gallery, index: request.index)
                    if let hero = decoded.1 {
                        MusicArtwork.cache(hero, url: request.url, high: true); MusicArtwork.store(hero, index: request.index, high: true)
                    }
                    self.renderer.invalidateLabel(request.index); self.engine.wake(); self.viewer.wake(); self.wakeForSceneChange()
                } catch { }
                guard let self, self.artworkRevision == revision, self.artworkTickets[request.index] == ticket else { return }
                self.artworkTasks[request.index] = nil; self.artworkTickets[request.index] = nil; self.runningArtwork[request.index] = nil
                self.pumpArtwork()
            }
        }
    }
    private var wheelAccumulated: CGFloat = 0
    private var libraryScroll = MusicLibraryScroll()
    private var detailScroll = MusicDetailScroll()

    /// Resolution multiplier (relative to points, capped by the screen's backing scale) while still,
    /// and while moving: motion trades a little sharpness for a steady 120 fps.
    var stillScale: CGFloat = 1.5
    var motionScale: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["RL_MOTION_SCALE"] ?? "") ?? 1.25)
    private var pixelBudget = RenderQuality.pixelBudget
    private var ratioCap: CGFloat = 2
    private var settleFrames = 0

    /// Pixel size of the last drawable (main thread), for the settings summary.
    var renderedSize: CGSize { metalLayer.drawableSize }

    /// Resolution and renderer settings from the quality preferences.
    func applyQuality(_ q: RenderQuality, superPerformance: Bool) {
        // Pixel ratio is capped by the screen; the percentage then supersamples beyond it.
        let scale = min(CGFloat(q.pixelRatio), backing) * CGFloat(q.scale) / 100
        stillScale = scale
        motionScale = Experience.music ? scale : max(0.5, min(scale, backing) * 0.75)
        ratioCap = CGFloat(q.pixelRatio)
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
    static func adaptiveEffectsOff(level: Int, moving: Bool) -> Int {
        // A hover settling must not switch the lighting model. Music keeps native
        // pixels and consistent occlusion; optimize its draw work instead of popping AO.
        Experience.music ? 0 : (moving ? effectsOff[max(0, min(3, level))] : 0)
    }
    static func musicFrameRate(idle: Bool, detail: Bool) -> Float { idle && detail ? 20 : 60 }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var link: CAMetalDisplayLink?
    private var renderThread: Thread?
    private var lastTimestamp: CFTimeInterval = 0
    private var wasIdleRate = false
    private let stats = FrameStats()
    private var downPoint = CGPoint.zero
    private var lastDragPoint = CGPoint.zero
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
        l.preferredFrameRateRange = Experience.music ? CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60) : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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
    private var lastBacking: CGFloat = 2

    private func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        points = bounds.size
        backing = window?.backingScaleFactor ?? 2
        stillScale = min(ratioCap, backing) * stillScale / max(0.01, min(ratioCap, lastBacking))
        lastBacking = backing
        applyScale(animating ? motionScale : stillScale)
        engine.wake()
        if viewer.isOpen { viewer.wake() }
    }

    private func applyScale(_ requested: CGFloat) {
        var scale = min(requested, max(backing, 1) * 2)
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
        let idle = viewerOpen ? viewer.isMusicPlaybackOnly : engine.idleOnly
        if idle != wasIdleRate {
            wasIdleRate = idle
            if Experience.music {
                let rate = Self.musicFrameRate(idle: idle, detail: viewerOpen || engine.detailRequested)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            } else {
                link.preferredFrameRateRange = idle
                    ? CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
                    : (level >= 3 ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120))
            }

        }
        // Choose the resolution for the *next* frame: modest while moving, full once still.
        let moving = animating && !idle
        if Experience.music { applyScale(stillScale) } else if moving { applyScale(min(motionScale, Self.motionScales[level])) } else { applyScale(stillScale) }
        if !animating {
            settleFrames -= 1
            if settleFrames <= 0 { link.isPaused = true }
        }
        let drawable = update.drawable
        let aspect = Float(drawable.texture.width) / Float(drawable.texture.height)
        var frame = viewerOpen ? viewer.makeFrame(aspect: aspect) : engine.makeFrame(aspect: aspect)
        frame.effectsOff |= Self.adaptiveEffectsOff(level: level, moving: moving)
        renderer.render(frame, to: drawable.texture, present: drawable)
        if moving { adapt(link) }
        stats.reason = (viewerOpen ? "viewer" : engine.activityReason) + " | lvl " + String(level)
        stats.record(interval: dt, tick: tickEnd - cpuStart, encode: CACurrentMediaTime() - tickEnd, gpu: renderer)
    }

    /// Escalate when frames cost more than the refresh budget; relax after a long calm stretch.
    private func adapt(_ link: CAMetalDisplayLink) {
        let budget = Experience.music || level >= 3 ? 16.0 : 7.6
        let gpu = renderer.smoothedGPUms
        if gpu > budget { overBudget += 1; underBudget = 0 } else if gpu < budget * 0.5 { underBudget += 1; overBudget = 0 } else { overBudget = 0; underBudget = 0 }
        if overBudget > 20 && level < 3 {
            level += 1; overBudget = 0
            if level == 3 { link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60) }
        } else if underBudget > 240 && level > 0 {
            level -= 1; underBudget = 0
            if level < 3 { link.preferredFrameRateRange = Experience.music ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120) }
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
        lastDragPoint = downPoint
        if event.clickCount == 2 {
            if Experience.music && engine.detailRequested { engine.resetMusicInspection(); drag = .none; return }
            if viewer.isOpen { viewer.reset(animated: true); drag = .none; return }
            if canPick(), let (index, cell) = card(at: downPoint) { onSelect?(index, cell); onOpen?(); drag = .none; return }
        }
        if viewer.isOpen { drag = event.modifierFlags.contains(.option) ? .pan : .orbit; return }
        drag = engine.canInspect ? .inspect : .none
        if Experience.music, case .inspect = drag { engine.beginMusicInspection() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastDragPoint.x), dy = Float(lastDragPoint.y - point.y), h = Float(bounds.height)
        lastDragPoint = point
        switch drag {
        case .inspect: if Experience.music { engine.inspect(dx: dx, dy: dy) } else { engine.rotate(by: dx * 0.004) }
        case .orbit: viewer.orbit(dx: dx, dy: dy, viewHeight: h)
        case .pan: viewer.pan(dx: dx, dy: dy, viewHeight: h)
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if Experience.music, case .inspect = drag { engine.endMusicInspection() }
        drag = .none
        guard !viewer.isOpen else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - downPoint.x, p.y - downPoint.y) < 6, canPick(), let (index, cell) = card(at: p) else { return }
        onSelect?(index, cell)
    }

    override func rightMouseDown(with event: NSEvent) { if Experience.music && engine.detailRequested { lastDragPoint = convert(event.locationInWindow, from: nil); drag = .inspect; engine.beginMusicInspection() } else if viewer.isOpen { drag = .pan } }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { if Experience.music, case .inspect = drag { engine.endMusicInspection() }; drag = .none }

    override func scrollWheel(with event: NSEvent) {
        if viewer.isOpen {
            viewer.dolly(scrollDelta: Float(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
            return
        }
        guard canPick() || (Experience.music && engine.detailRequested) else { return }
        if Experience.music && engine.detailRequested {
            if let direction = detailScroll.consume(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                                    phase: event.phase, momentum: event.momentumPhase,
                                                    precise: event.hasPreciseScrollingDeltas, time: event.timestamp) { onStep?(direction) }
            return
        }
        if Experience.music && !engine.detailRequested {
            // Normalize AppKit's horizontal scroll sign to a right/up coordinate pair
            // before projecting onto the two on-screen diagonal shelf axes.
            switch libraryScroll.consume(dx: -event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                         phase: event.phase, momentum: event.momentumPhase,
                                         precise: event.hasPreciseScrollingDeltas, time: event.timestamp) {
            case .column(let direction): onStepColumn?(direction)
            case .song(let direction): onStep?(direction)
            case .none: break
            }
            return
        }
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
    override func magnify(with event: NSEvent) {
        if Experience.music && engine.detailRequested { engine.zoomInspection(by: Float(event.magnification)) } else if viewer.isOpen { viewer.dolly(factor: exp(-Float(event.magnification))) }
    }
    override func rotate(with event: NSEvent) {
        if Experience.music && engine.detailRequested { engine.rotate(by: Float(event.rotation) * .pi / 180 * 0.65) } else if viewer.isOpen { viewer.roll(by: Float(event.rotation) * .pi / 180) }
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
