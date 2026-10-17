import AVFoundation
import Combine
import Foundation

@MainActor
final class MusicPlayer: ObservableObject {
    enum Status: String { case idle, loading, playing, paused, failed }
    @Published private(set) var status: Status = .idle
    @Published private(set) var current: MusicTrack?
    @Published private(set) var contextTracks: [MusicTrack] = []
    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var collectionID: String?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    @Published private(set) var activeSource: MusicSource?
    @Published var source: MusicSource = .xinghai {
        didSet { if persistent { UserDefaults.standard.set(source.rawValue, forKey: "rhine-music-source") } }
    }
    @Published var shuffle = true {
        didSet { if persistent { UserDefaults.standard.set(shuffle, forKey: "rhine-music-shuffle") } }
    }
    @Published var volume: Float = 0.65 {
        didSet {
            player.volume = max(0, min(1, volume))
            if persistent { UserDefaults.standard.set(volume, forKey: "rhine-song-volume") }
        }
    }
    var onTrackChanged: ((MusicTrack?) -> Void)?
    var onTransportChanged: ((Bool) -> Void)?
    private let service: any MusicProviding
    private let persistent: Bool
    private let player = AVPlayer()
    let rhythm = MusicRhythm()
    private var rhythmTask: Task<Void, Never>?
    private var systemControls: MusicSystemControls?
    var canSeek: Bool { player.currentItem?.status == .readyToPlay }
    private var index = 0
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var transportObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?

    init(service: any MusicProviding, persistent: Bool = true) {
        self.service = service; self.persistent = persistent
        if persistent {
            source = MusicSource(rawValue: UserDefaults.standard.string(forKey: "rhine-music-source") ?? "") ?? .xinghai
            shuffle = UserDefaults.standard.object(forKey: "rhine-music-shuffle") as? Bool ?? true
            volume = UserDefaults.standard.object(forKey: "rhine-song-volume") as? Float ?? 0.65
        }
        player.volume = volume
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(self.duration - d) > 0.5 {
                    self.duration = d; self.systemControls?.update()
                }
            }
        }
        transportObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem != nil, self.status != .failed, self.status != .paused else { return }
                self.setStatus(self.player.timeControlStatus == .playing ? .playing : .loading)
            }
        }
        if persistent { systemControls = MusicSystemControls(player: self) }
    }

    func play(_ track: MusicTrack, in tracks: [MusicTrack], collectionID: String?) {
        var seen = Set<String>()
        let tracks = tracks.filter { seen.insert($0.id).inserted }
        guard tracks.contains(where: { $0.id == track.id }) else { return }
        contextTracks = tracks
        queue = shuffle ? [track] + tracks.filter { $0.id != track.id }.shuffled() : tracks
        index = queue.firstIndex(where: { $0.id == track.id }) ?? 0
        self.collectionID = collectionID
        start()
    }

    func selectPaused(_ track: MusicTrack, in tracks: [MusicTrack], collectionID: String?) {
        invalidate()
        contextTracks = tracks; queue = tracks; index = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
        self.collectionID = collectionID
        current = track; elapsed = 0; duration = track.duration; error = nil; activeSource = nil
        onTrackChanged?(track); setStatus(.paused)
    }

    func playCollection(_ tracks: [MusicTrack], collectionID: String) {
        guard let track = shuffle ? tracks.randomElement() : tracks.first else {
            error = "歌单还是空的，先从搜索加入歌曲"; return
        }
        play(track, in: tracks, collectionID: collectionID)
    }

    private func setStatus(_ next: Status) {
        status = next
        systemControls?.update()
        onTransportChanged?(next == .loading || next == .playing || next == .paused)
    }

    private func invalidate() {
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        rhythmTask?.cancel(); rhythmTask = nil; rhythm.reset()
        watchdog?.cancel(); watchdog = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }; failedObserver = nil
        player.pause(); player.replaceCurrentItem(with: nil)
    }

    private func start() {
        guard queue.indices.contains(index) else { return }
        invalidate()
        let track = queue[index], ticket = generation, preferred = source
        current = track; elapsed = 0; duration = track.duration; error = nil; activeSource = nil
        onTrackChanged?(track)
        setStatus(.loading)
        loadTask = Task { [weak self, service] in
            do {
                let url: URL
                let resolvedSource: MusicSource
                do {
                    url = try await service.resolve(track, source: preferred); resolvedSource = preferred
                } catch {
                    guard track.platform == "wy" else { throw error }
                    try Task.checkCancellation()
                    url = try await service.resolve(track, source: preferred.alternate); resolvedSource = preferred.alternate
                }
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                self.activeSource = resolvedSource
                self.install(url, ticket: ticket)
            } catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.fail("这首暂时无法播放。\(error.localizedDescription) 可以重试或换一首。")
            }
        }
    }

    private func install(_ url: URL, ticket: UUID) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        player.replaceCurrentItem(with: item)
        let rhythmTicket = rhythm.reset()
        rhythmTask = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                try Task.checkCancellation()
                guard let self, self.generation == ticket, self.player.currentItem === item, let track = tracks.first else { return }
                item.audioMix = self.rhythm.makeMix(track: track, ticket: rhythmTicket)
            } catch { /* Unsupported streams keep playing normally, without a fabricated waveform. */ }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.generation == ticket, self.player.currentItem === observed else { return }
                if observed.status == .readyToPlay {
                    self.player.play()
                } else if observed.status == .failed {
                    self.fail("音频加载失败，请重试或换一首。")
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.generation == ticket { self?.next() } }
        }
        failedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.generation == ticket { self?.fail("播放连接中断，可以重试或换一首。") } }
        }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.generation == ticket, self.status == .loading else { return }
            self.fail("加载时间太长了，请重试或换一首。")
        }
    }

    private func fail(_ text: String) {
        invalidate(); error = text; setStatus(.failed)
    }

    func toggle() {
        if status == .playing || status == .loading { pause() }
        else if status == .paused, player.currentItem != nil { setStatus(.loading); player.play() }
        else if current != nil { start() }
    }

    func pause() {
        if status == .loading { invalidate() } else { player.pause() }
        setStatus(.paused)
    }

    func stop() {
        invalidate(); current = nil; elapsed = 0; duration = 0; error = nil; activeSource = nil
        onTrackChanged?(nil)
        setStatus(.idle)
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 >= queue.count {
            let last = current?.id
            if shuffle {
                queue.shuffle()
                if queue.count > 1, queue[0].id == last { queue.swapAt(0, 1) }
            }
            index = 0
        } else { index += 1 }
        start()
    }

    func previous() {
        if elapsed > 3 { seek(0) }
        else if !queue.isEmpty { index = (index - 1 + queue.count) % queue.count; start() }
    }

    func seek(_ time: Double) {
        guard player.currentItem?.status == .readyToPlay, time.isFinite else { return }
        let seconds = max(0, min(duration, time))
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = seconds
        systemControls?.update()
    }
}
