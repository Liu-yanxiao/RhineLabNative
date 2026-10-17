import AppKit
import MediaPlayer

/// macOS routes its media keys and Control Center through the active Now Playing app.
@MainActor final class MusicSystemControls {
    enum Action { case play, pause, toggle, next, previous, stop, seek(Double) }
    private weak var player: MusicPlayer?
    private let commands = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []

    init(player: MusicPlayer) {
        self.player = player
        bind(commands.playCommand, .play); bind(commands.pauseCommand, .pause)
        bind(commands.togglePlayPauseCommand, .toggle)
        bind(commands.nextTrackCommand, .next); bind(commands.previousTrackCommand, .previous)
        bind(commands.stopCommand, .stop)
        let command = commands.changePlaybackPositionCommand
        let token = command.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = position.positionTime
            Task { @MainActor in _ = self?.perform(.seek(seconds)) }
            return .success
        }
        targets.append((command, token))
        update()
    }
    private func bind(_ command: MPRemoteCommand, _ action: Action) {
        let token = command.addTarget { [weak self] _ in
            Task { @MainActor in _ = self?.perform(action) }
            return .success
        }
        targets.append((command, token))
    }
    @discardableResult func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard let player, player.current != nil else { return .noSuchContent }
        return Self.perform(action, on: player)
    }
    @discardableResult static func perform(_ action: Action, on player: MusicPlayer) -> MPRemoteCommandHandlerStatus {
        guard player.current != nil else { return .noSuchContent }
        switch action {
        case .play: if player.status != .playing && player.status != .loading { player.toggle() }
        case .pause: player.pause()
        case .toggle: player.toggle()
        case .next: player.next()
        case .previous: player.previous()
        case .stop: player.stop()
        case .seek(let seconds): guard player.canSeek else { return .commandFailed }; player.seek(seconds)
        }
        return .success
    }
    func update() {
        guard let player else { return }
        let available = player.current != nil
        commands.playCommand.isEnabled = available
        commands.pauseCommand.isEnabled = available
        commands.togglePlayPauseCommand.isEnabled = available
        commands.nextTrackCommand.isEnabled = !player.queue.isEmpty
        commands.previousTrackCommand.isEnabled = !player.queue.isEmpty
        commands.stopCommand.isEnabled = available
        commands.changePlaybackPositionCommand.isEnabled = available && player.canSeek
        guard player.current != nil else {
            info.nowPlayingInfo = nil; info.playbackState = .stopped; return
        }
        info.nowPlayingInfo = Self.metadata(for: player)
        info.playbackState = player.status == .playing ? .playing : .paused
    }
    static func metadata(for player: MusicPlayer) -> [String: Any]? {
        guard let track = player.current else { return nil }
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let url = track.artwork, let cover = MusicArtwork.cached(url) {
            let image = NSImage(cgImage: cover, size: NSSize(width: cover.width, height: cover.height))
            values[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        return values
    }
    func disconnect() {
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
    }
    deinit { for (command, token) in targets { command.removeTarget(token) } }
}
