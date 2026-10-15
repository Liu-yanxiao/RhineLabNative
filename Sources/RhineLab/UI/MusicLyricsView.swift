import SwiftUI

struct MusicLyricsView: View {
    let track: MusicTrack
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    @StateObject private var lyrics = MusicLyricsState()
    @State private var following = true
    @State private var retry = 0
    private var time: Double { player.current?.id == track.id ? player.elapsed : 0 }
    var body: some View {
        Group {
            if lyrics.loading {
                state("正在载入歌词", subtitle: "")
            } else if let error = lyrics.error {
                VStack(alignment: .leading, spacing: 18) {
                    state(error, subtitle: "音乐播放不受影响")
                    Button("重新加载 ↗") { retry += 1 }.buttonStyle(RhineButtonStyle()).font(Theme.font(14))
                }
            } else if let document = lyrics.document, !document.lines.isEmpty {
                content(document)
            } else {
                state("暂无歌词", subtitle: "这首歌曲还没有提供歌词，继续享受音乐。")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: track.id + "-" + String(retry)) {
                following = true
                await lyrics.load(track, service: model.musicService)
            }
    }

    private func state(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("LYRICS").font(Theme.font(10)).tracking(1.5).foregroundStyle(pal.muted)
            Text(title).font(Theme.font(23, .light))
            if !subtitle.isEmpty { Text(subtitle).font(Theme.font(13)).foregroundStyle(pal.muted) }
        }.padding(.top, 40)
    }

    private func content(_ document: MusicLyrics) -> some View {
        let active = document.activeLine(at: time)
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(document.timed ? "同步歌词" : "文本歌词").font(Theme.font(10)).tracking(1)
                    Spacer()
                    if document.timed && !following {
                        Button("回到当前歌词 ↗") {
                            following = true
                            if let active { withAnimation(.easeOut(duration: 0.45)) { proxy.scrollTo(active, anchor: .center) } }
                        }.buttonStyle(RhineButtonStyle()).font(Theme.font(11))
                    }
                }.foregroundStyle(pal.muted).frame(height: 36)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(document.lines) { line in
                            Button {
                                if let start = line.time { player.seek(start); following = true }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(line.text).font(Theme.font(23, active == line.id ? .semibold : .regular))
                                        .foregroundStyle(active == line.id ? pal.ink : pal.muted)
                                    if let translated = line.translation {
                                        Text(translated).font(Theme.font(13)).foregroundStyle(pal.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(RhineButtonStyle()).disabled(line.time == nil || player.current?.id != track.id || !player.canSeek)
                                .id(line.id)
                        }
                    }.padding(.vertical, 55).padding(.horizontal, 2)
                }.scrollIndicators(.hidden)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                                 .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay { MusicLyricsScrollIntent { following = false }.allowsHitTesting(false) }
                    .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in following = false })
                    .onAppear { if let active { proxy.scrollTo(active, anchor: .center) } }
                    .onChange(of: active) { _, current in
                        guard following, let current else { return }
                        withAnimation(model.reduced ? nil : .easeOut(duration: 0.45)) { proxy.scrollTo(current, anchor: .center) }
                    }
            }
        }
    }
}

/// Trackpad scrolling must release lyric following as well as a direct drag.
private struct MusicLyricsScrollIntent: NSViewRepresentable {
    var onScroll: () -> Void
    final class Observer: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, event.momentumPhase.isEmpty,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                   abs(event.scrollingDeltaY) > 0 { self.onScroll?() }
                return event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Observer { let view = Observer(); view.onScroll = onScroll; return view }
    func updateNSView(_ view: Observer, context: Context) { view.onScroll = onScroll }
}
