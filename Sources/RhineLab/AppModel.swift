import SwiftUI
import AppKit
import QuartzCore

enum Mode { case boot, archive, detail }
enum Modal { case search, saved, settings, library }

@MainActor
final class AppModel: ObservableObject {
    let engine: ArchiveEngine
    let viewer: ViewerEngine
    let sceneView: ArchiveView
    let audio = TerminalAudio()
    let musicService: MusicService
    let musicLibrary: MusicLibrary
    let musicPlayer: MusicPlayer
    let musicPresentation: MusicPresentation
    var musicItem: MusicSceneItem { let items = MusicCatalog.items; return items[min(selected, items.count - 1)] }
    var sceneTrack: MusicTrack? { musicItem.track }
    var sceneTracks: [MusicTrack] { MusicCatalog.tracks(collection) }
    var sceneNumber: Int { (columnFiles.firstIndex(of: selected) ?? 0) + 1 }
    var sceneArtwork: URL? { sceneTrack != nil ? sceneTrack?.artwork : musicLibrary.tracks(collection).first?.artwork }
    var collection: MusicCollection { musicItem.collection! }
    private var inspectionTask: Task<Void, Never>?
    @Published var freeSceneReady = false
    @Published var musicDetailTab = 0
    @Published var musicSearchQuery = ""
    @Published var musicSearchResultQuery = ""
    @Published var musicSearchResults: [MusicTrack] = []
    @Published var clickPoint: CGPoint = .zero
    @Published var clickID = 0
    /// Set by headless screenshot rendering: no audio device, no sound.
    nonisolated(unsafe) static var headless = false

    @Published var mode: Mode = .boot { didSet { updateWatermark(); updateRhythmState() } }
    @Published var selected = 0
    @Published var hover: Int?
    @Published var modal: Modal? { didSet { updateWatermark() } }
    @Published var tab = 0 {
        didSet { if mode == .detail, oldValue != tab { audio.play(.uiTick) } }
    }
    @Published var bootID = 0
    /// Wall-clock origin of the opening; app time = BootMotion.startTime + elapsed.
    private(set) var bootStart = Date()
    private var bootTimer: Timer?
    private var lastBootTime: Double?
    /// Window size in points (used to map 3D overlay points into the 1920 × 1080 stage).
    var windowSize = CGSize(width: 1920, height: 1080)
    @Published var saved: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "rhine-saved") ?? [])
    @Published var toast: String?
    @Published var accessLog: [(id: String, time: String)] = []
    @Published var reduced = UserDefaults.standard.bool(forKey: "rhine-reduced") { didSet { applyPrefs(); audio.play(.confirm) } }
    @Published var idleDrift = AppModel.loadIdleDrift() { didSet { applyPrefs(); audio.play(.confirm) } }
    @Published var windowOpacity = WindowAppearance.opacity(UserDefaults.standard.object(forKey: "rhine-window-opacity") as? Double ?? 1) {
        didSet { if !Self.headless { UserDefaults.standard.set(windowOpacity, forKey: "rhine-window-opacity") }; applyWindowAppearance() }
    }
    @Published var windowGlass = UserDefaults.standard.bool(forKey: "rhine-window-glass") {
        didSet { if !Self.headless { UserDefaults.standard.set(windowGlass, forKey: "rhine-window-glass") }; applyWindowAppearance() }
    }
    @Published var rhythmEnabled = UserDefaults.standard.object(forKey: "rhine-rhythm-enabled") as? Bool ?? true {
        didSet { if !Self.headless { UserDefaults.standard.set(rhythmEnabled, forKey: "rhine-rhythm-enabled") }; updateRhythmState() }
    }
    @Published var dark = (Experience.music ? UserDefaults.standard.object(forKey: "rhine-music-dark-5") as? Bool ?? true : UserDefaults.standard.bool(forKey: "rhine-dark")) { didSet { applyTheme(); audio.play(.tick) } }
    @Published var audioPrefs = AppModel.loadAudioPrefs() { didSet { saveAudio() } }
    @Published var quality = RenderQuality.load() { didSet { if oldValue != quality { applyQuality() } } }
    @Published var superPerformance = UserDefaults.standard.bool(forKey: "rhine-super") { didSet { applyQuality(); audio.play(.confirm) } }
    /// What the renderer actually uses: the super performance mode overrides the saved quality.
    var effectiveQuality: RenderQuality { superPerformance ? .superPerformance : quality }
    @Published var columnMemory: [Int]
    // 360° viewer
    @Published var viewerOpen = false
    @Published var viewerExploded = false
    @Published var viewerClear = true
    @Published var viewerStatus = "已组装"
    private var toastTask: Task<Void, Never>?
    private var monitor: Any?
    private var pointerMonitor: Any?
    private var pointerDrag = false
    private var rightPointerDrag = false

    var records: [ArchiveRecord] { Archive.records }
    var record: ArchiveRecord { Archive.records[selected] }
    var lane: Int { Archive.location(of: selected).lane }
    var columnFiles: [Int] { Archive.columnFiles(lane) }
    private var now: Double { CACurrentMediaTime() }

    init(bootPreview: Bool = false, renderer providedRenderer: MetalRenderer? = nil) {
        let service = MusicService()
        musicService = service
        musicLibrary = MusicLibrary(storageURL: Self.headless ? nil : MusicLibrary.defaultStorage, includeBuiltins: Experience.music)
        musicPlayer = MusicPlayer(service: service, persistent: !Self.headless)
        musicPresentation = MusicPresentation(library: musicLibrary, player: musicPlayer)
        guard let renderer = providedRenderer ?? MetalRenderer() else { fatalError("Metal is not available") }
        engine = ArchiveEngine()
        viewer = ViewerEngine()
        sceneView = ArchiveView(engine: engine, viewer: viewer, renderer: renderer)
        selected = musicPresentation.selectedIndex
        columnMemory = Archive.columns.indices.map { Archive.columnFiles($0).first ?? 0 }
        sceneView.canPick = { [weak self] in self?.mode == .archive && self?.modal == nil }
        sceneView.onHover = { [weak self] in
            if self?.hover != $0 { self?.hover = $0 }
        }
        sceneView.onSelect = { [weak self] index, cell in self?.select(index, navigation: .cell(cell)) }
        sceneView.onBrowseSelect = { [weak self] index, cell in self?.select(index, navigation: .cell(cell), sceneAlreadySelected: true) }
        sceneView.onOpen = { [weak self] in self?.open() }
        sceneView.onStep = { [weak self] direction in
            guard let self else { return }
            if self.mode == .detail && Experience.music { self.navigateSong(direction) } else { self.stepFile(direction) }
        }
        sceneView.onStepColumn = { [weak self] direction in self?.stepColumn(direction) }
        engine.onInspectionChanged = { [weak self] ready in Task { @MainActor in self?.freeSceneReady = ready } }
        viewer.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.viewerStatus = status }
        }
        applyPrefs()
        applyTheme(immediate: true)
        applyQuality()
        if !Self.headless { configureInterfaceAudio() }
        musicPresentation.onSelection = { [weak self] index, changed in self?.syncMusicCatalogue(index: index, changed: changed) }
        musicPlayer.onTransportChanged = { [weak self] busy in
            guard let self else { return }
            let playing = self.musicPlayer.status == .playing
            self.engine.setMusicPlaying(playing)
            self.viewer.setMusicPlaying(playing)
            self.updateRhythmState()
            if !Self.headless { self.configureInterfaceAudio() }
        }
        if Self.headless && !bootPreview && Experience.music { finishBoot() }
        else {
            audio.setScene(.boot)
            startBootClock()
            if Experience.music && !Self.headless { prepareSceneArtwork() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
        if Experience.music {
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .scrollWheel, .magnify, .rotate]) { [weak self] event in
                guard let self else { return event }
                let handled = MainActor.assumeIsolated { self.routeSceneEvent(event) }
                return handled ? nil : event
            }
        }
    }

    /// SwiftUI's transparent stage covers the native scene. Forward only its open 3D region;
    /// controls, text fields, menus and sheets retain their normal native event handling.
    private func routeSceneEvent(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseDown, event.window === sceneView.window, sceneView.bounds.width > 0 {
            let p = sceneView.convert(event.locationInWindow, from: nil)
            clickPoint = CGPoint(x: p.x / sceneView.bounds.width * 1920, y: (1 - p.y / sceneView.bounds.height) * 1080)
            clickID += 1
        }
        guard modal == nil, (event.window ?? NSApp.keyWindow) === sceneView.window else {
            sceneView.clearPointerHover()
            if pointerDrag || rightPointerDrag { sceneView.cancelPointerInteraction() }
            pointerDrag = false; rightPointerDrag = false; return false
        }
        let point = sceneView.convert(event.locationInWindow, from: nil)
        let bounds = sceneView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let x = point.x / bounds.width * 1920, y = (1 - point.y / bounds.height) * 1080
        let sceneArea = x > 130 && x < 960 && y > 235 && y < 890
        switch event.type {
        case .mouseMoved:
            if sceneArea && mode == .archive && !viewerOpen && !pointerDrag && !rightPointerDrag {
                sceneView.mouseMoved(with: event)
            } else { sceneView.clearPointerHover() }
            // Passive movement must still reach SwiftUI button and control hover handlers.
            return false
        case .mouseExited where event.trackingArea?.owner as? ArchiveView === sceneView:
            sceneView.clearPointerHover(); return false
        case .leftMouseDown where sceneArea: pointerDrag = true; sceneView.mouseDown(with: event); return true
        case .leftMouseDragged where pointerDrag: sceneView.mouseDragged(with: event); return true
        case .leftMouseUp where pointerDrag: pointerDrag = false; sceneView.mouseUp(with: event); return true
        case .rightMouseDown where sceneArea && (viewer.isOpen || engine.detailRequested): rightPointerDrag = true; sceneView.rightMouseDown(with: event); return true
        case .rightMouseDragged where rightPointerDrag: sceneView.rightMouseDragged(with: event); return true
        case .rightMouseUp where rightPointerDrag: rightPointerDrag = false; sceneView.rightMouseUp(with: event); return true
        case .scrollWheel where sceneArea: sceneView.scrollWheel(with: event); return true
        case .magnify where sceneArea && (viewer.isOpen || engine.detailRequested): sceneView.magnify(with: event); return true
        case .rotate where sceneArea && (viewer.isOpen || engine.detailRequested): sceneView.rotate(with: event); return true
        default: return false
        }
    }

    private func applyPrefs() {
        engine.reduced = reduced
        engine.idleDrift = idleDrift
        viewer.reduced = reduced
        updateRhythmState()
        engine.wake()
        if !Self.headless {
            UserDefaults.standard.set(reduced, forKey: "rhine-reduced")
            UserDefaults.standard.set(idleDrift, forKey: Experience.music ? "rhine-music-idle-1" : "rhine-idle")
        }
    }

    static func loadIdleDrift(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Experience.music ? "rhine-music-idle-1" : "rhine-idle") as? Bool ?? Experience.music
    }

    private func applyTheme(immediate: Bool = false) {
        if !Self.headless { UserDefaults.standard.set(dark, forKey: Experience.music ? "rhine-music-dark-5" : "rhine-dark") }
        engine.setTheme(dark: dark, time: now, immediate: immediate)
        viewer.theme = dark ? 1 : 0
        applyWindowAppearance()
    }

    func applyWindowAppearance(to window: NSWindow? = nil) {
        guard !Self.headless, let window = window ?? sceneView.window else { return }
        WindowAppearance.apply(to: window, opacity: windowOpacity, glass: windowGlass, dark: dark)
    }
    private func updateRhythmState() {
        musicPlayer.rhythm.enabled = Experience.music && rhythmEnabled && !reduced && mode == .detail
            && musicPlayer.status == .playing && musicPlayer.current?.id == sceneTrack?.id
    }

    private func updateWatermark() {
        guard Experience.music else { return }
        let mark: SIMD4<Float>
        if mode == .boot { mark = .zero }
        else if let modal {
            switch modal {
            case .library: mark = SIMD4(0.51, 0.59, 0.39, 0.13)
            case .search: mark = SIMD4(0.80, 0.59, 0.42, 0.15)
            case .saved: mark = SIMD4(0.52, 0.56, 0.40, 0.14)
            case .settings: mark = SIMD4(0.82, 0.72, 0.36, 0.14)
            }
        } else { mark = mode == .detail ? SIMD4(0.78, 0.56, 0.40, 0.12) : SIMD4(0.52, 0.34, 0.40, 0.055) }
        engine.setWatermark(mark, behindScene: modal == nil, immediate: Self.headless)
    }

    private func applyQuality() {
        if !Self.headless {
            quality.save()
            UserDefaults.standard.set(superPerformance, forKey: "rhine-super")
        }
        sceneView.applyQuality(effectiveQuality, superPerformance: superPerformance)
    }

    /// "实际渲染 1600 × 900 · MSAA 4× · 纹理 16×" for the settings dialog.
    var qualitySummary: String {
        let q = effectiveQuality
        let size = sceneView.renderedSize
        let prefix = superPerformance ? "超级性能模式已启用 · 画质设置暂被覆盖，关闭后恢复 · " : ""
        return prefix + "实际渲染 \(Int(size.width)) × \(Int(size.height)) · \(q.antialias ? "MSAA 4×" : "无抗锯齿") · 纹理 \(q.anisotropy)×"
    }

    private static func loadAudioPrefs() -> AudioPreferences {
        let d = UserDefaults.standard
        var p = AudioPreferences()
        if d.object(forKey: "rhine-sound") != nil { p.sound = d.bool(forKey: "rhine-sound") }
        if d.object(forKey: "rhine-music") != nil { p.music = d.bool(forKey: "rhine-music") }
        if d.object(forKey: "rhine-sound-volume") != nil { p.soundVolume = d.float(forKey: "rhine-sound-volume") }
        if d.object(forKey: "rhine-music-volume") != nil { p.musicVolume = d.float(forKey: "rhine-music-volume") }
        return p
    }

    private func saveAudio() {
        let d = UserDefaults.standard
        d.set(audioPrefs.sound, forKey: "rhine-sound")
        d.set(audioPrefs.music, forKey: "rhine-music")
        d.set(audioPrefs.soundVolume, forKey: "rhine-sound-volume")
        d.set(audioPrefs.musicVolume, forKey: "rhine-music-volume")
        if !Self.headless { configureInterfaceAudio() }
    }

    private func configureInterfaceAudio() {
        var prefs = audioPrefs
        if Experience.music { prefs.music = false }
        audio.configure(prefs)
    }

    private func syncMusicCatalogue(index: Int, changed: Bool) {
        if changed {
            sceneView.clearMusicArtwork()
            sceneView.renderer.clearLabels()
            columnMemory = Archive.columns.indices.map { Archive.columnFiles($0).first ?? 0 }
            engine.resetCatalogue(selected: index, time: now)
        }
        select(index)
        sceneView.wakeForSceneChange()
    }

    private func prepareSceneArtwork() {
        var urls: [Int: URL] = [:]
        for (index, item) in MusicCatalog.items.enumerated() { if let url = item.artwork { urls[index] = url } }
        sceneView.prepareMusicArtwork(selected: selected, urls: urls, high: mode == .detail)
    }

    func locatePlaying() {
        musicPresentation.locatePlaying()
        if mode == .archive { open() }
    }

    func playSelection() {
        if let track = sceneTrack {
            if musicPlayer.current?.id == track.id && musicPlayer.collectionID == (collection.kind == .temporary ? nil : collection.id) { musicPlayer.toggle() }
            else { musicPlayer.play(track, in: sceneTracks, collectionID: collection.kind == .temporary ? nil : collection.id) }
        } else { musicPlayer.playCollection(sceneTracks, collectionID: collection.id) }
    }

    func selectCollection(_ collection: MusicCollection) {
        guard let index = MusicCatalog.items.firstIndex(where: { $0.collection?.id == collection.id }) else { return }
        select(index)
    }

    func navigateSong(_ direction: Int) {
        let files = columnFiles
        guard files.count > 1, let current = files.firstIndex(of: selected) else { return }
        let next = files[(current + direction + files.count) % files.count]
        let keepPaused = musicPlayer.status == .paused || musicPlayer.status == .idle || musicPlayer.status == .failed
        select(next, navigation: .row(direction))
        guard let track = sceneTrack else { return }
        let id = collection.kind == .temporary ? nil : collection.id
        if keepPaused { musicPlayer.selectPaused(track, in: sceneTracks, collectionID: id) }
        else { musicPlayer.play(track, in: sceneTracks, collectionID: id) }
    }

    // MARK: Opening clock

    func bootTime(at date: Date) -> Double { BootMotion.startTime + date.timeIntervalSince(bootStart) }

    /// Headless screenshots position the opening at a given app time.
    func setBootTime(_ t: Double) { bootStart = Date().addingTimeInterval(BootMotion.startTime - t) }

    private func startBootClock() {
        bootStart = Date()
        lastBootTime = nil
        bootTimer?.invalidate()
        guard !Self.headless else { return }
        bootTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickBoot() }
        }
    }

    private func tickBoot() {
        advanceBoot(to: bootTime(at: Date()))
    }

    func advanceBoot(to t: Double) {
        guard mode == .boot else { bootTimer?.invalidate(); bootTimer = nil; return }
        if !Self.headless {
            audio.updateBoot(appTime: t, previous: lastBootTime)
            if let previous = lastBootTime, BootMotion.hasTyping(between: previous + 5, and: t + 5) { audio.play(.key) }
        }
        lastBootTime = t
        if t >= BootMotion.endTime { finishBoot() }
    }

    // MARK: Flow

    func finishBoot() {
        guard mode == .boot else { return }
        bootTimer?.invalidate(); bootTimer = nil
        mode = .archive
        engine.targetReveal = 1
        engine.select(selected, time: now)
        engine.wake()
        audio.setScene(.archive)
        if Experience.music && !Self.headless { prepareSceneArtwork() }
    }

    /// ENTER SYSTEM: the opening is cut short by the user.
    func skipBoot() {
        guard mode == .boot else { return }
        audio.play(.uiTick)
        finishBoot()
    }

    func select(_ index: Int, navigation: ArchiveNavigation? = nil, sceneAlreadySelected: Bool = false) {
        guard mode != .boot else { return }
        let index = (index + records.count) % records.count
        let keepDetail = Experience.music && mode == .detail
        if mode == .detail && !keepDetail { mode = .archive; engine.setDetail(false, time: now); audio.setScene(.archive) }
        if case .lane(let direction) = navigation {
            audio.play(.column, pan: Float(direction) * 0.45)
        } else if index != selected || navigation != nil {
            audio.play(.tick)
        }
        selected = index
        if Experience.music { musicPresentation.select(index) }
        columnMemory[lane] = index
        tab = 0
        if !sceneAlreadySelected { engine.select(index, navigation: navigation, time: now) }
        if keepDetail { engine.setDetail(true, time: now) }
        if Experience.music {
            if viewer.isOpen { viewer.selectLabel(index) }
            prepareSceneArtwork()
            updateRhythmState()
        }
    }

    func stepFile(_ direction: Int) {
        let files = columnFiles
        guard files.count > 1, let i = files.firstIndex(of: selected) else { return }
        select(files[(i + direction + files.count) % files.count], navigation: .row(direction))
    }

    func stepColumn(_ direction: Int) {
        let next = Archive.wrap(lane + direction, Archive.columns.count)
        select(columnMemory[next], navigation: .lane(direction))
    }

    func open() {
        guard mode == .archive else { return }
        mode = .detail
        freeSceneReady = false
        accessLog.insert((record.id, Date.now.formatted(.dateTime.hour().minute().second())), at: 0)
        engine.setDetail(true, time: now)
        audio.setScene(.detail)
        audio.play(.open)
        if Experience.music { prepareSceneArtwork(); sceneView.wakeForSceneChange() }
    }

    func back() {
        guard mode == .detail else { return }
        mode = .archive
        inspectionTask?.cancel()
        freeSceneReady = false
        if Experience.music { viewer.close(); prepareSceneArtwork() }
        sceneView.wakeForSceneChange()
        engine.setDetail(false, time: now)
        audio.setScene(.archive)
        audio.play(.back)
    }

    func present(_ m: Modal) {
        guard mode != .boot, !viewerOpen else { return }
        sceneView.cancelPointerInteraction()
        modal = m
        audio.play(.pageOpen)
    }

    func dismissModal() {
        guard modal != nil else { return }
        modal = nil
        audio.play(.pageClose)
    }

    // MARK: 360° viewer

    func openViewer() {
        guard mode == .detail, !viewerOpen else { return }
        viewerExploded = false
        viewerClear = true
        viewerStatus = "已组装"
        viewer.open(labelIndex: selected)
        viewerOpen = true
        audio.setScene(.viewer)
        audio.play(.pageOpen)
    }

    func closeViewer() {
        guard viewerOpen else { return }
        viewerOpen = false
        viewer.close()
        engine.wake()
        audio.setScene(mode == .detail ? .detail : .archive)
        audio.play(.pageClose)
    }

    func setViewerExploded(_ on: Bool) {
        guard viewerOpen, viewerExploded != on else { return }
        viewerExploded = on
        viewer.setExploded(on)
        audio.play(on ? .explode : .assemble)
    }

    func setViewerClear(_ on: Bool) {
        guard viewerOpen, viewerClear != on else { return }
        viewerClear = on
        viewer.setClear(on)
        audio.play(.uiTick)
    }

    func resetViewer() {
        guard viewerOpen else { return }
        viewer.reset(animated: true)
        audio.play(.uiTick)
    }

    // MARK: Saved files and export

    func toggleSaved() {
        let id = record.id
        if saved.contains(id) { saved.remove(id); notify("已从收藏移除 \(id)") }
        else { saved.insert(id); notify("已收藏 \(id)") }
        UserDefaults.standard.set(Array(saved), forKey: "rhine-saved")
        audio.play(.confirm)
    }

    func notify(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func export() {
        let r = record
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RHINE-LAB-\(r.id).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = """
        RHINE LAB · ANALYSIS OS
        FILE \(r.id) — \(r.en)
        \(r.title) / \(r.category)

        DEPARTMENT: \(r.department)
        COLLECTION: \(r.date)
        RELATED: \(r.lead)
        CLEARANCE: \(r.clearance)

        ABSTRACT
        \(r.abstract)

        RESEARCH NOTES
        \(r.findings.enumerated().map { "\(String(format: "%02d", $0.offset + 1)). \($0.element)" }.joined(separator: "\n"))

        SOURCE: \(r.source)
        """
        do { try text.write(to: url, atomically: true, encoding: .utf8); notify("已导出 \(r.id)") }
        catch { notify("导出失败") }
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]) != [] { return false }
        if mode == .boot {
            if event.keyCode == 36 || event.keyCode == 53 { skipBoot(); return true }
            return false
        }
        if modal != nil {
            if event.keyCode == 53 { dismissModal(); return true }
            return false
        }
        if let editor = event.window?.firstResponder as? NSTextView, editor.isEditable { return false }
        if Experience.music && mode == .detail {
            switch event.keyCode {
            case 123, 126: navigateSong(-1)
            case 124, 125: navigateSong(1)
            case 53: back()
            case 115: engine.resetMusicInspection()
            case 49: if musicPlayer.current == nil { playSelection() } else { musicPlayer.toggle() }
            case 45: navigateSong(1)
            case 24, 69: engine.zoomInspection(by: 0.08)
            case 27, 78: engine.zoomInspection(by: -0.08)
            default: return false
            }
            return true
        }
        if viewerOpen {
            switch event.keyCode {
            case 53: if Experience.music { back() } else { closeViewer() }
            case 115: resetViewer()                                 // home
            case 123: viewer.panStep(SIMD2(-1, 0))
            case 124: viewer.panStep(SIMD2(1, 0))
            case 126: viewer.panStep(SIMD2(0, 1))
            case 125: viewer.panStep(SIMD2(0, -1))
            case 24, 69: viewer.dolly(factor: 1 / 1.12)             // = / keypad +
            case 27, 78: viewer.dolly(factor: 1.12)                 // - / keypad -
            case 49 where Experience.music:
                if musicPlayer.current == nil { playSelection() }
                else { musicPlayer.toggle() }
            case 45 where Experience.music: musicPlayer.next()
            default: return false
            }
            return true
        }
        switch (mode, event.keyCode) {
        case (_, 49) where Experience.music:
            if musicPlayer.current == nil { playSelection() }
            else { musicPlayer.toggle() }
            return true
        case (_, 45) where Experience.music: navigateSong(1); return true
        case (_, 44) where event.characters == "/": present(.search); return true
        case (_, 123): stepColumn(-1); return true
        case (_, 124): stepColumn(1); return true
        case (_, 126): stepFile(-1); return true
        case (_, 125): stepFile(1); return true
        case (.archive, 36), (.archive, 76): open(); return true
        case (.detail, 53): back(); return true
        default: return false
        }
    }
}

extension AppModel {
    /// Replay the opening sequence.
    func replay() {
        modal = nil
        closeViewer()
        if mode == .detail { engine.setDetail(false, time: CACurrentMediaTime()) }
        engine.targetReveal = 0
        mode = .boot
        bootID += 1
        audio.restartBoot()
        audio.setScene(.boot)
        startBootClock()
    }
}
