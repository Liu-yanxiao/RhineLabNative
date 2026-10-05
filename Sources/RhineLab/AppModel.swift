import SwiftUI
import AppKit
import QuartzCore

enum Mode { case boot, archive, detail }
enum Modal { case search, saved, settings }

@MainActor
final class AppModel: ObservableObject {
    let engine: ArchiveEngine
    let viewer: ViewerEngine
    let sceneView: ArchiveView
    let audio = TerminalAudio()
    /// Set by headless screenshot rendering: no audio device, no sound.
    nonisolated(unsafe) static var headless = false

    @Published var mode: Mode = .boot
    @Published var selected = 0
    @Published var hover: Int?
    @Published var modal: Modal?
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
    @Published var idleDrift = UserDefaults.standard.object(forKey: "rhine-idle") as? Bool ?? false { didSet { applyPrefs(); audio.play(.confirm) } }
    @Published var dark = UserDefaults.standard.bool(forKey: "rhine-dark") { didSet { applyTheme(); audio.play(.tick) } }
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

    var records: [ArchiveRecord] { Archive.records }
    var record: ArchiveRecord { Archive.records[selected] }
    var lane: Int { Archive.location(of: selected).lane }
    var columnFiles: [Int] { Archive.columnFiles(lane) }
    private var now: Double { CACurrentMediaTime() }

    init() {
        guard let renderer = MetalRenderer() else { fatalError("Metal is not available") }
        engine = ArchiveEngine()
        viewer = ViewerEngine()
        sceneView = ArchiveView(engine: engine, viewer: viewer, renderer: renderer)
        columnMemory = Archive.columns.indices.map { Archive.columnFiles($0).first ?? 0 }
        sceneView.canPick = { [weak self] in self?.mode == .archive && self?.modal == nil }
        sceneView.onHover = { [weak self] in
            if self?.hover != $0 { self?.hover = $0 }
        }
        sceneView.onSelect = { [weak self] index, cell in self?.select(index, navigation: .cell(cell)) }
        sceneView.onStep = { [weak self] direction in self?.stepFile(direction) }
        viewer.onStatusChanged = { [weak self] status in
            Task { @MainActor in self?.viewerStatus = status }
        }
        applyPrefs()
        applyTheme(immediate: true)
        applyQuality()
        if !Self.headless { audio.configure(audioPrefs) }
        startBootClock()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    private func applyPrefs() {
        engine.reduced = reduced
        engine.idleDrift = idleDrift
        viewer.reduced = reduced
        engine.wake()
        UserDefaults.standard.set(reduced, forKey: "rhine-reduced")
        UserDefaults.standard.set(idleDrift, forKey: "rhine-idle")
    }

    private func applyTheme(immediate: Bool = false) {
        UserDefaults.standard.set(dark, forKey: "rhine-dark")
        engine.setTheme(dark: dark, time: now, immediate: immediate)
        viewer.theme = dark ? 1 : 0
    }

    private func applyQuality() {
        quality.save()
        UserDefaults.standard.set(superPerformance, forKey: "rhine-super")
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
        if !Self.headless { audio.configure(audioPrefs) }
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
        guard mode == .boot else { bootTimer?.invalidate(); bootTimer = nil; return }
        let t = bootTime(at: Date())
        audio.updateBoot(appTime: t, previous: lastBootTime)
        if let previous = lastBootTime, BootMotion.hasTyping(between: previous + 5, and: t + 5) { audio.play(.key) }
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
    }

    /// ENTER SYSTEM: the opening is cut short by the user.
    func skipBoot() {
        guard mode == .boot else { return }
        audio.play(.uiTick)
        finishBoot()
    }

    func select(_ index: Int, navigation: ArchiveNavigation? = nil) {
        guard mode != .boot else { return }
        let index = (index + records.count) % records.count
        if mode == .detail { mode = .archive; engine.setDetail(false, time: now); audio.setScene(.archive) }
        if case .lane(let direction) = navigation {
            audio.play(.column, pan: Float(direction) * 0.45)
        } else if index != selected || navigation != nil {
            audio.play(.tick)
        }
        selected = index
        columnMemory[lane] = index
        tab = 0
        engine.select(index, navigation: navigation, time: now)
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
        accessLog.insert((record.id, Date.now.formatted(.dateTime.hour().minute().second())), at: 0)
        engine.setDetail(true, time: now)
        audio.setScene(.detail)
        audio.play(.open)
    }

    func back() {
        guard mode == .detail else { return }
        mode = .archive
        engine.setDetail(false, time: now)
        audio.setScene(.archive)
        audio.play(.back)
    }

    func present(_ m: Modal) {
        guard mode != .boot, !viewerOpen else { return }
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
        if viewerOpen {
            switch event.keyCode {
            case 53: closeViewer()                                  // esc
            case 115: resetViewer()                                 // home
            case 123: viewer.panStep(SIMD2(-1, 0))
            case 124: viewer.panStep(SIMD2(1, 0))
            case 126: viewer.panStep(SIMD2(0, 1))
            case 125: viewer.panStep(SIMD2(0, -1))
            case 24, 69: viewer.dolly(factor: 1 / 1.12)             // = / keypad +
            case 27, 78: viewer.dolly(factor: 1.12)                 // - / keypad -
            default: break
            }
            return true
        }
        switch (mode, event.keyCode) {
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
