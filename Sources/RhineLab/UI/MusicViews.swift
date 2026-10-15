import SwiftUI

struct MusicStage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    var body: some View {
        ZStack {
            Group {
            RhineMusicBrand().place(left: 59, top: 64).rhineReveal()
            HStack(spacing: 24) {
                NavButton(action: { model.present(.library) }) { Text("01  音乐库") }
                NavButton(action: { model.present(.search) }) { Text("02  搜索") }
                NavButton(action: { model.present(.saved) }) { Text("03  收藏") }
                MusicThemeSwitch()
                NavButton(action: { model.present(.settings) }) { Image(systemName: "slider.horizontal.3") }
                Rectangle().fill(pal.line).frame(width: 1, height: 24)
                CompactMusicTransport()
            }.font(Theme.font(13)).place(right: 59, top: 124).rhineReveal(1)
            MusicPlaybackStatus().frame(width: 390).place(right: 59, top: 162)
            if model.mode == .detail { MusicDetail() } else { MusicOverview() }
            HStack {
                Text(model.sceneTrack != nil ? "\(model.collection.title)  ·  \(model.sceneTracks.count) TRACKS" : "\(library.collections.count) 张歌单  /  \(library.count) 首音乐")
                Spacer()
                Text("RHINE MUSIC")
            }.font(Theme.font(11)).tracking(1).foregroundStyle(pal.body).padding(.horizontal, 59).place(bottom: 35)
            }.opacity(model.modal == nil ? 1 : 0).allowsHitTesting(model.modal == nil)
            if model.modal == .search || model.modal == .saved { MusicSearch(savedOnly: model.modal == .saved).transition(.opacity) }
            if model.modal == .library { MusicLibraryPanel().transition(.opacity) }
            if model.modal == .settings { MusicSettings().transition(.opacity) }
            Toast()
        }.foregroundStyle(pal.ink).animation(model.reduced ? nil : .easeOut(duration: 0.3), value: model.mode)
            .animation(model.reduced ? nil : .easeOut(duration: 0.25), value: model.modal)
    }
}

struct MusicThemeSwitch: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var pal
    @Namespace private var marker
    var body: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                Button { model.dark = dark } label: {
                    HStack(spacing: 8) {
                        Text(dark ? "−" : "+").font(Theme.font(13))
                        Text(dark ? "深夜" : "暖昼").font(Theme.font(11))
                    }.padding(.horizontal, 13).padding(.vertical, 8)
                        .foregroundStyle(model.dark == dark ? pal.onSolid : pal.muted)
                        .background {
                            if model.dark == dark { Rectangle().fill(pal.solid).matchedGeometryEffect(id: "theme", in: marker) }
                        }
                }.buttonStyle(RhineButtonStyle()).accessibilityLabel(dark ? "深夜主题" : "暖昼主题")
            }
        }.padding(2).overlay(alignment: .bottom) { Rectangle().fill(pal.line.opacity(0.7)).frame(height: 1) }
            .animation(.easeInOut(duration: 0.65), value: model.dark)
    }
}

private struct CompactMusicTransport: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MusicPlayer
    var body: some View {
        HStack(spacing: 16) {
            Button { model.locatePlaying() } label: {
                Text(player.current?.title ?? "选择一首音乐").font(Theme.font(13)).lineLimit(1)
                    .frame(width: 150, alignment: .trailing)
            }.buttonStyle(RhineButtonStyle()).disabled(player.current == nil).help("定位正在播放的歌曲")
            MusicTimeline(compact: true).frame(width: 185).opacity(player.current == nil ? 0.35 : 1)
            Button { player.previous() } label: { Image(systemName: "backward.end") }.disabled(player.current == nil).help("上一首")
            Button {
                if player.current == nil { model.playSelection() } else { player.toggle() }
            } label: { Image(systemName: player.status == .playing || player.status == .loading ? "pause.fill" : "play.fill").contentTransition(.symbolEffect(.replace)) }
                .help("播放 / 暂停（空格）")
            Button { player.next() } label: { Image(systemName: "forward.end") }.disabled(player.current == nil).help("下一首")
            Button { player.stop() } label: { Image(systemName: "stop") }.help("停止")
        }.font(Theme.font(16)).buttonStyle(RhineButtonStyle())

    }
}

/// A thin timeline uses the same rules and square markers as the archive interface.
private struct MusicTimeline: View {
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    var compact = false
    @State private var seek: Double?
    @State private var hovering = false
    var body: some View {
        HStack(spacing: compact ? 8 : 14) {
            Text(MusicTrack.clock(seek ?? player.elapsed)).frame(width: compact ? 32 : 40, alignment: .leading)
            GeometryReader { geo in
                let progress = CGFloat(min(1, max(0, (seek ?? player.elapsed) / max(1, player.duration))))
                ZStack(alignment: .leading) {
                    Rectangle().fill(pal.line).frame(height: 1)
                    Rectangle().fill(pal.ink).frame(width: geo.size.width * progress, height: 1)
                    Rectangle().fill(pal.ink).frame(width: 5, height: 5)
                        .offset(x: max(0, geo.size.width * progress - 2.5)).opacity(hovering || seek != nil ? 1 : 0)
                }.frame(height: 20).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.canSeek else { return }
                            seek = min(1, max(0, value.location.x / max(1, geo.size.width))) * player.duration
                        }
                        .onEnded { _ in if let seek { player.seek(seek) }; seek = nil })
                    .onHover { hovering = $0 }
                    .accessibilityElement().accessibilityLabel("播放进度")
                    .accessibilityValue("\(MusicTrack.clock(player.elapsed)) / \(MusicTrack.clock(player.duration))")
                    .accessibilityAdjustableAction { direction in
                        if direction == .increment { player.seek(player.elapsed + 5) }
                        if direction == .decrement { player.seek(player.elapsed - 5) }
                    }
            }.frame(height: 20)
            Text(MusicTrack.clock(player.duration)).frame(width: compact ? 32 : 40, alignment: .trailing)
        }.font(Theme.font(compact ? 10 : 11)).monospacedDigit().foregroundStyle(pal.muted)
            .onChange(of: player.current?.id) { _, _ in seek = nil }
    }
}

private struct MusicPlaybackStatus: View {
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if player.status == .loading { Text("正在加载…").font(Theme.font(12)).foregroundStyle(pal.muted) }
            if let error = player.error { Text(error).font(Theme.font(12)).foregroundStyle(pal.accent).multilineTextAlignment(.trailing) }
        }
    }
}

private struct MusicOverview: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    var body: some View {
        let item = model.musicItem, tracks = model.sceneTracks, files = model.columnFiles
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.track != nil ? "MUSIC ARCHIVE  ／  \(model.collection.title)" : "MUSIC ARCHIVE  ／  私人收藏")
                    .font(Theme.font(11)).tracking(1.2).foregroundStyle(pal.body)
                HStack {
                    Text(String(format: "%@ %03d", item.track != nil ? "TRACK" : "PLAYLIST", model.sceneNumber))
                    Spacer()
                    Text(item.track != nil ? "ONLINE" : "COLLECTION").font(Theme.font(10)).foregroundStyle(pal.body)
                }.font(Theme.font(12)).tracking(0.8).padding(.top, 23)
                Rectangle().fill(pal.ink.opacity(0.7)).frame(height: 1).padding(.top, 14)
                Text(item.title).font(Theme.font(46, .semibold)).lineLimit(2).minimumScaleFactor(0.75)
                    .frame(width: 540, height: 114, alignment: .topLeading).clipped()
                    .contentTransition(.opacity).animation(model.reduced ? nil : .easeOut(duration: 0.22), value: item.title)
                    .padding(.top, 24).accessibilityIdentifier("music-overview-title")
                Text(item.subtitle).font(Theme.font(18)).lineLimit(1).frame(height: 24, alignment: .leading).padding(.top, 12)
                HStack(spacing: 20) {
                    if let track = item.track {
                        Text(track.album).lineLimit(1)
                        Text(track.time).monospacedDigit()
                    } else { Text("\(tracks.count) 首歌曲") }
                }.font(Theme.font(12)).foregroundStyle(pal.body).padding(.top, 25)
                Button { model.open() } label: {
                    HStack { Text(item.track != nil ? "打开播放详情" : "打开歌单"); Spacer(); Text("↗").font(Theme.font(24)) }
                        .font(Theme.font(16)).padding(.vertical, 19)
                }.buttonStyle(RhineButtonStyle()).padding(.top, 22)
                if let track = item.track {
                    HStack(spacing: 28) {
                        MusicPlayingMark(active: player.current?.id == track.id && player.status == .playing)
                        Button { model.navigateSong(-1) } label: { Image(systemName: "backward.end") }.help("上一首")
                        Button { model.playSelection() } label: { Text(player.current?.id == track.id && player.status == .playing ? "暂停" : "播放") }
                        Button { model.navigateSong(1) } label: { Image(systemName: "forward.end") }.help("下一首")
                    }.buttonStyle(RhineButtonStyle()).font(Theme.font(14)).padding(.top, 16)
                }
            }.frame(width: 540, alignment: .leading).place(left: 1318, top: 347)
            VStack(alignment: .leading, spacing: 15) {
                Text(item.track != nil ? "TRACK / SELECT" : "PLAYLIST / SELECT").font(Theme.font(10)).tracking(1.5)
                HStack(alignment: .firstTextBaseline, spacing: 15) {
                    Text(String(format: "%02d", model.sceneNumber)).font(Theme.font(58, .light)).contentTransition(.numericText())
                    Text("/ \(String(format: "%02d", item.track != nil ? tracks.count : library.collections.count))")
                        .font(Theme.font(13)).foregroundStyle(pal.body)
                }
            }.place(left: 60, bottom: 115)
            let rail = MusicRail.window(count: files.count, selected: files.firstIndex(of: model.selected) ?? 0)
            HStack(spacing: 24) {
                ArrowButton(glyph: "↖", size: 26) { model.stepFile(-1) }
                HStack(spacing: 8) {
                    Text(rail.lowerBound > 0 ? "⋯" : "").frame(width: 12)
                    ForEach(Array(files[rail]), id: \.self) { index in
                        Button { model.select(index) } label: {
                            Rectangle().fill(index == model.selected ? pal.ink : pal.line)
                                .frame(width: 2, height: index == model.selected ? 33 : 12)
                                .frame(width: 24, height: 40).contentShape(Rectangle())
                        }.buttonStyle(RhineButtonStyle()).help(Archive.records[index].title)
                    }
                    Text(rail.upperBound < files.count ? "⋯" : "").frame(width: 12)
                }.foregroundStyle(pal.body).frame(width: 540, height: 40)
                ArrowButton(glyph: "↘", size: 26) { model.stepFile(1) }
            }.frame(width: 700, alignment: .leading).place(left: 505, bottom: 131)
            if Archive.columns.count > 1 {
                HStack(spacing: 30) {
                    ArrowButton(glyph: "↙", size: 25) { model.stepColumn(-1) }
                    VStack(spacing: 7) { Text(String(format: "%02d / %02d", model.lane + 1, Archive.columns.count)).font(Theme.font(10)); Text(model.collection.title).font(Theme.font(14)).lineLimit(1) }.frame(width: 200)
                    ArrowButton(glyph: "↗", size: 25) { model.stepColumn(1) }
                }.place(left: 1318, bottom: 135)
            }
            Text("拖动浏览    /    ↖ ↘ 同列歌曲    /    ↙ ↗ 切换歌单    /    ENTER 打开    /    SPACE 播放暂停")
                .font(Theme.font(10)).foregroundStyle(pal.body).place(left: 505, bottom: 60)
        }
    }
}

private struct MusicPlayingMark: View {
    @Environment(\.palette) private var pal
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<4) { i in
                    Rectangle().fill(active ? pal.accent : pal.muted)
                        .frame(width: 2, height: active ? 5 + 11 * abs(sin(time * 2.2 + Double(i))) : 3)
                }
            }.frame(width: 20, height: 18)
        }.accessibilityLabel(active ? "正在播放" : "播放已暂停")
    }
}

private struct MusicDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    private var tab: Int {
        get { model.musicDetailTab }
        nonmutating set { model.musicDetailTab = newValue }
    }
    @Namespace private var tabMarker
    @State private var renaming = false
    @State private var name = ""
    var body: some View {
        let item = model.musicItem, tracks = model.sceneTracks, track = item.track
        let playingSelection = track != nil && player.current?.id == track?.id && player.status == .playing
        ZStack {
            Button { model.back() } label: {
                HStack(spacing: 25) {
                    Text("←  返回音乐库")
                    Text("ESC").font(Theme.font(10)).foregroundStyle(pal.muted).padding(4)
                        .overlay(Rectangle().stroke(pal.line.opacity(0.7), lineWidth: 1))
                }
            }.buttonStyle(RhineButtonStyle()).font(Theme.font(13)).place(left: 59, top: 245)
            VStack(alignment: .leading, spacing: 13) {
                Text(String(format: "%@ / %03d", track != nil ? "TRACK" : "PLAYLIST", model.sceneNumber)).font(Theme.font(12)).tracking(1.8)
                Text(model.freeSceneReady ? "轻拖封面，松手缓慢回正  /  ← ↑ 上一首  ↓ → 下一首" : "正在展开封面…").font(Theme.font(11)).foregroundStyle(pal.muted)
                Button("复位封面 ↗") { model.engine.resetMusicInspection() }.buttonStyle(RhineButtonStyle()).font(Theme.font(12)).disabled(!model.freeSceneReady)
            }.place(left: 60, bottom: 140)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(String(format: "%@ / %03d", track != nil ? "TRACK" : "PLAYLIST", model.sceneNumber)).tracking(1.5)
                    Spacer()
                    NavButton(action: { model.navigateSong(-1) }) { Text("↑ 上一首") }
                    NavButton(action: { model.navigateSong(1) }) { Text("下一首 ↓") }.padding(.leading, 20)
                }.font(Theme.font(11)).foregroundStyle(pal.muted)
                Text(track?.title ?? model.collection.title).font(Theme.font(40, .semibold))
                    .lineLimit(2).minimumScaleFactor(0.75).frame(height: 102, alignment: .topLeading)
                    .contentTransition(.opacity).padding(.top, 27)
                Text(track?.artist ?? model.collection.subtitle).font(Theme.font(17)).lineLimit(1).foregroundStyle(pal.muted)
                MusicRule().padding(.top, 24)
                HStack(spacing: 20) {
                    Text(model.collection.title).tracking(0.8)
                    Text("/").foregroundStyle(pal.line)
                    Text(track?.album ?? "PRIVATE COLLECTION").lineLimit(1)
                    Spacer()
                    Text(track?.time ?? "\(tracks.count) 首歌曲").monospacedDigit()
                }.font(Theme.font(11)).foregroundStyle(pal.muted).padding(.top, 17).padding(.bottom, 27)
                HStack(spacing: 28) {
                    tabButton(0, "01", "歌单")
                    tabButton(1, "02", "歌词")
                    tabButton(2, "03", "歌曲信息")
                    Spacer()
                    if track != nil { MusicPlayingMark(active: player.current?.id == track?.id && player.status == .playing) }
                    Button { model.playSelection() } label: { Label(playingSelection ? "暂停" : "播放", systemImage: playingSelection ? "pause" : "play") }
                        .buttonStyle(RhineButtonStyle()).font(Theme.font(13)).disabled(tracks.isEmpty)
                }.padding(.top, 7).padding(.bottom, 14)
                    .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
                if tab == 0 {
                    if tracks.isEmpty {
                        MusicEmptyState(title: "这里还没有歌曲", detail: "从搜索中选择音乐，即可开始试听。")
                            .padding(.top, 35)
                        Button("搜索音乐 ↗") { model.present(.search) }.buttonStyle(RhineButtonStyle()).font(Theme.font(14)).padding(.top, 22)
                        Spacer()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, song in
                                        NativeMusicRow(track: song, number: index + 1, onPlay: {
                                            player.play(song, in: tracks, collectionID: model.collection.kind == .temporary ? nil : model.collection.id)
                                        }, removingFrom: item.collection).id(song.id)
                                    }
                                }
                            }.scrollIndicators(.hidden)
                                .onAppear { if let id = track?.id { proxy.scrollTo(id, anchor: .top) } }
                                .onChange(of: track?.id) { _, id in
                                    if let id { withAnimation(.easeOut(duration: 0.46)) { proxy.scrollTo(id, anchor: .top) } }
                                }
                        }
                    }
                } else if tab == 1 {
                    if let track { MusicLyricsView(track: track) }
                    else { MusicEmptyState(title: "选择一首音乐", detail: "播放时，歌词会随歌曲展开。").padding(.top, 40); Spacer() }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.collection.kind == .custom {
                            HStack {
                                if renaming {
                                    TextField("歌单名称", text: $name).textFieldStyle(.plain)
                                        .onSubmit { library.rename(model.collection, to: name); renaming = false }
                                    Button("保存") { library.rename(model.collection, to: name); renaming = false }
                                } else {
                                    Text(model.collection.title)
                                    Button { name = model.collection.title; renaming = true } label: { Image(systemName: "pencil") }
                                }
                            }.font(Theme.font(17)).buttonStyle(RhineButtonStyle())
                        }
                        HStack(alignment: .top, spacing: 50) {
                            fact("SOURCE / 来源", track?.platform == "msr" ? "塞壬唱片-MSR" : "网易云音乐")
                            fact("QUEUE / 歌单", "\(tracks.count) 首歌曲")
                            fact("PLAYBACK / 顺序", player.shuffle ? "随机播放" : "顺序播放")
                        }

                        Text(track?.album ?? item.subtitle).font(Theme.font(22))
                        Text(track?.artist ?? "私人音乐收藏").font(Theme.font(16)).foregroundStyle(pal.muted)
                        if track != nil {
                            MusicTimeline().padding(.top, 10)
                            HStack(spacing: 30) {
                                Button { model.navigateSong(-1) } label: { Label("上一首", systemImage: "backward.end") }
                                Button { player.toggle() } label: { Label(player.status == .playing ? "暂停" : "继续播放", systemImage: player.status == .playing ? "pause" : "play") }
                                Button { model.navigateSong(1) } label: { Label("下一首", systemImage: "forward.end") }
                            }.buttonStyle(RhineButtonStyle()).font(Theme.font(15))
                        }
                    }.padding(.top, 30)
                    Spacer()
                }
            }.frame(width: 760, height: 700, alignment: .topLeading)
                .padding(24).background(RhineReadingField())
                .place(left: 1030, top: 240).rhineReveal(1)
        }.onChange(of: item.id) { _, _ in renaming = false }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(Theme.font(10)).tracking(0.7).foregroundStyle(pal.muted)
            Text(value).font(Theme.font(14)).lineLimit(1)
        }
    }
    private func tabButton(_ index: Int, _ number: String, _ title: String) -> some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { tab = index } } label: {
            HStack(spacing: 9) { Text(number).font(Theme.font(9)); Text(title).font(Theme.font(14)) }
                .foregroundStyle(tab == index ? pal.ink : pal.muted)
        }.buttonStyle(RhineButtonStyle()).overlay(alignment: .bottom) {
            if tab == index { Rectangle().fill(pal.ink).frame(height: 1).matchedGeometryEffect(id: "detail-tab", in: tabMarker).offset(y: 15) }
        }.accessibilityAddTraits(tab == index ? .isSelected : [])
    }
}

private struct MusicRule: View {
    @Environment(\.palette) private var pal
    var body: some View {
        Rectangle().fill(pal.ink.opacity(0.75)).frame(height: 1)
            .overlay(alignment: .leading) { Rectangle().fill(pal.ink).frame(width: 5, height: 5) }
    }
}

private struct MusicEmptyState: View {
    @Environment(\.palette) private var pal
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Theme.font(24, .light))
            Text(detail).font(Theme.font(15)).foregroundStyle(pal.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeMusicRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    @State private var hovering = false
    let track: MusicTrack
    let number: Int
    let onPlay: () -> Void
    var removingFrom: MusicCollection?
    var body: some View {
        let active = player.current?.id == track.id
        HStack(spacing: 18) {
            Button(action: onPlay) {
                HStack(spacing: 24) {
                    Text(active ? (player.status == .paused ? "Ⅱ" : "▶") : String(format: "%02d", number))
                        .font(Theme.font(12)).monospacedDigit().foregroundStyle(active ? pal.accent : pal.muted).frame(width: 24)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(track.title).font(Theme.font(18)).foregroundStyle(active || hovering ? pal.accent : pal.ink).lineLimit(1)
                        Text(track.artist).font(Theme.font(12)).foregroundStyle(pal.muted).lineLimit(1)
                    }
                    Spacer()
                    Text(track.time).font(Theme.font(12)).monospacedDigit().foregroundStyle(pal.muted).frame(width: 46, alignment: .trailing)
                }.contentShape(Rectangle())
            }.buttonStyle(RhineButtonStyle())
            Button { library.toggleLike(track) } label: { Image(systemName: library.liked.contains(track.id) ? "heart.fill" : "heart").contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: library.liked.contains(track.id)).symbolEffectsRemoved(model.reduced || systemReduced) }
                .buttonStyle(RhineButtonStyle()).foregroundStyle(library.liked.contains(track.id) ? pal.accent : pal.muted).help("收藏")
            Menu {
                ForEach(library.editable) { item in Button("加入 \(item.title)") { library.add(track, to: item) } }
                if let removingFrom { Button("从歌单移除") { library.remove(track, from: removingFrom) } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("更多操作")
        }.foregroundStyle(pal.ink).padding(.horizontal, 8).frame(height: 76)
            .background(hovering || active ? pal.ink.opacity(0.025) : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line.opacity(0.55)).frame(height: 1) }
            .onHover { hovering = $0 }
    }
}

/// All music subpages share the archive's existing sheet, typography and fine rules.
private struct MusicPanel<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var pal
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    private var section: String { subtitle == "YOUR COLLECTION" ? "01" : subtitle == "SEARCH" ? "02" : subtitle == "FAVORITES" ? "03" : "04" }
    var body: some View {
        ZStack {
            Rectangle().fill(pal.paper.opacity(model.dark ? 0.72 : 0.52))
                .contentShape(Rectangle()).onTapGesture { model.dismissModal() }
            LinearGradient(colors: [.clear, pal.paper.opacity(model.dark ? 0.45 : 0.25)], startPoint: .leading, endPoint: .trailing).allowsHitTesting(false)
            RhineMusicBrand().place(left: 59, top: 64)
            HStack(spacing: 35) {
                Text("RHINE / \(subtitle)").tracking(1.4).foregroundStyle(pal.muted)
                Button { model.dismissModal() } label: { HStack(spacing: 18) { Text("返回"); Text("×").font(Theme.font(23)) } }
                    .buttonStyle(RhineButtonStyle()).accessibilityLabel("关闭\(title)")
            }.font(Theme.font(12)).place(right: 59, top: 124)
            VStack(alignment: .leading, spacing: 24) {
                Text("INDEX / \(section)").font(Theme.font(11)).tracking(2).foregroundStyle(pal.muted)
                Text(title).font(Theme.font(48, .semibold))
                Text(subtitle).font(Theme.font(12)).tracking(2.6).foregroundStyle(pal.muted)
                MusicRule().frame(width: 280).padding(.top, 18)
                Text("RHINE LAB. LLC.\nMUSIC ARCHIVE / PRIVATE TERMINAL")
                    .font(Theme.font(10)).tracking(1).lineSpacing(8).foregroundStyle(pal.muted).padding(.top, 7)
            }.frame(width: 420, alignment: .leading).place(left: 90, top: 300).rhineReveal()
            Text(section).font(Theme.font(100, .light)).foregroundStyle(pal.ink.opacity(0.17))
                .place(left: 90, bottom: 135).rhineReveal(2)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(width: 1175, height: 700, alignment: .topLeading)
                .contentShape(Rectangle()).place(left: 680, top: 270).rhineReveal(1)
            HStack {
                Text("POWERED BY RHINE LAB  ▬")
                Spacer()
                Text("ESC / RETURN")
            }.font(Theme.font(10)).tracking(1).foregroundStyle(pal.muted)
                .padding(.horizontal, 59).place(bottom: 44)
        }.foregroundStyle(pal.ink)
    }
}

private struct MusicLibraryPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.palette) private var pal
    @State private var name = ""
    var body: some View {
        MusicPanel(title: "音乐库", subtitle: "YOUR COLLECTION") {
            HStack(spacing: 25) {
                TextField("", text: $name, prompt: Text("新歌单名称").foregroundColor(pal.muted)).textFieldStyle(.plain).font(Theme.font(21)).onSubmit(create)
                Button("创建歌单 ＋") { create() }.buttonStyle(RhineButtonStyle()).font(Theme.font(16))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.vertical, 18).overlay(alignment: .bottom) { MusicRule() }.padding(.bottom, 30)
            HStack {
                Text("PLAYLIST / 歌单")
                Spacer()
                Text("\(library.collections.count) 张歌单 · \(library.count) 首歌曲")
            }.font(Theme.font(11)).tracking(0.8).foregroundStyle(pal.muted).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(library.collections.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.dismissModal(); model.selectCollection(item)
                            if model.mode == .archive { model.open() }
                        } label: {
                            HStack(spacing: 28) {
                                Text(String(format: "%02d", index + 1)).font(Theme.font(14)).monospacedDigit().foregroundStyle(pal.muted).frame(width: 30)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.title).font(Theme.font(22))
                                    Text(item.english).font(Theme.font(10)).tracking(1).foregroundStyle(pal.muted)
                                }
                                Spacer()
                                Text("\(library.tracks(item).count) 首").font(Theme.font(14)).foregroundStyle(pal.muted)
                                Text("↗").font(Theme.font(22)).padding(.leading, 20)
                            }.padding(.vertical, 23).contentShape(Rectangle())
                        }.buttonStyle(RhineButtonStyle()).overlay(alignment: .bottom) { Rectangle().fill(pal.line.opacity(0.5)).frame(height: 1) }
                            .contextMenu { if item.kind == .custom { Button("删除歌单") { library.delete(item) } } }
                    }
                }
            }.scrollIndicators(.hidden)
            if let error = library.storageError { Text(error).font(Theme.font(13)).foregroundStyle(pal.accent) }
            if library.canUndoDeletion { Button("撤销删除歌单") { library.undoDeletion() }.buttonStyle(RhineButtonStyle()).font(Theme.font(16)).padding(.vertical, 20) }
        }
    }
    private func create() {
        guard let item = library.create(name) else { return }
        model.dismissModal(); model.selectCollection(item); if model.mode == .archive { model.open() }
    }
}

private struct MusicSearch: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    let savedOnly: Bool
    private var query: String { model.musicSearchQuery }
    private var results: [MusicTrack] {
        get { model.musicSearchResults }
        nonmutating set { model.musicSearchResults = newValue }
    }
    @State private var submittedQuery = ""
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var revision = UUID()
    @FocusState private var focused: Bool
    var tracks: [MusicTrack] { savedOnly ? library.tracks(library.collections[0]) : results }
    var body: some View {
        MusicPanel(title: savedOnly ? "喜欢的音乐" : "搜索音乐", subtitle: savedOnly ? "FAVORITES" : "SEARCH") {
            if !savedOnly {
                HStack(spacing: 20) {
                    MagnifierGlyph(size: 23)
                    TextField("", text: $model.musicSearchQuery, prompt: Text("歌曲、歌手或专辑").foregroundColor(pal.muted)).textFieldStyle(.plain).font(Theme.font(23)).focused($focused).onSubmit(search)
                    Button("搜索 →", action: search).buttonStyle(RhineButtonStyle()).font(Theme.font(19)).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (loading && query.trimmingCharacters(in: .whitespacesAndNewlines) == submittedQuery))
                }.padding(.vertical, 20).overlay(alignment: .bottom) { MusicRule() }.padding(.bottom, 28)
            }
            HStack {
                Text(savedOnly ? "SAVED TRACKS / 收藏" : "SEARCH RESULTS / 搜索结果")
                Spacer()
                if loading { RhineScanProgress() }
                Text(loading ? "搜索中…" : "\(tracks.count) 首歌曲")
            }.font(Theme.font(11)).tracking(0.8).foregroundStyle(pal.muted).padding(.bottom, 12)
            if let error { Text(error).font(Theme.font(15)).foregroundStyle(pal.accent).padding(.bottom, 20) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        NativeMusicRow(track: track, number: index + 1, onPlay: { player.play(track, in: tracks, collectionID: savedOnly ? "favorites" : nil) })
                    }
                    if tracks.isEmpty && !loading {
                        MusicEmptyState(title: savedOnly ? "喜欢的声音，留在这里。" : "寻找想听的音乐。",
                                        detail: savedOnly ? "点击歌曲旁的爱心，即可收藏。" : "输入歌曲、歌手或专辑，点击结果即可试听。")
                            .padding(.top, 58)
                    }
                }
            }.scrollIndicators(.hidden)
        }.onAppear {
            focused = !savedOnly
            // Resume a previously submitted query through the shared cache/in-flight request.
            if !savedOnly, !model.musicSearchResultQuery.isEmpty,
               model.musicSearchResultQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) { search() }
        }.onDisappear { task?.cancel() }
    }
    private func search() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !loading || keyword != submittedQuery else { return }
        task?.cancel(); revision = UUID(); let ticket = revision
        submittedQuery = keyword; loading = true; error = nil
        var seen = Set<String>()
        var local: [MusicTrack] = []
        for collection in library.collections {
            for song in library.tracks(collection) {
                let searchable = [song.title, song.artist, song.album].joined(separator: " ")
                if searchable.localizedCaseInsensitiveContains(keyword), seen.insert(song.id).inserted { local.append(song) }
            }
        }
        if model.musicSearchResultQuery != keyword { results = local }
        model.musicSearchResultQuery = keyword
        task = Task {
            do {
                let songs = try await model.musicService.search(keyword)
                guard !Task.isCancelled, revision == ticket else { return }
                var ids = Set<String>()
                results = (local + songs).filter { ids.insert($0.id).inserted }
                if results.isEmpty { error = "没有找到歌曲，试试其他关键词。" }
            } catch {
                guard !Task.isCancelled, revision == ticket else { return }
                self.error = results.isEmpty ? error.localizedDescription : "线上结果暂未更新，先保留当前匹配结果。"
            }
            if revision == ticket { loading = false }
        }

    }
}

private struct MusicChoice: View {
    @Environment(\.palette) private var pal
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(selected ? pal.ink : pal.muted)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? pal.ink : Color.clear).frame(height: 1) }
        }.buttonStyle(RhineButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MusicSettingRow<Content: View>: View {
    @Environment(\.palette) private var pal
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 20) { Text(title); Spacer(); content }
            .font(Theme.font(17)).frame(height: 85)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line.opacity(0.5)).frame(height: 1) }
    }
}

private struct MusicSettings: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.palette) private var pal
    var body: some View {
        MusicPanel(title: "设置", subtitle: "PREFERENCES") {
            HStack(alignment: .top, spacing: 70) {
                VStack(alignment: .leading, spacing: 0) {
                    section("01", "播放", "PLAYBACK")
                    MusicSettingRow(title: "优先音源") {
                        HStack(spacing: 6) {
                            ForEach(MusicSource.allCases, id: \.self) { source in
                                MusicChoice(title: source.label, selected: player.source == source) { player.source = source }
                            }
                        }
                    }
                    MusicSettingRow(title: "歌曲音量") {
                        Slider(value: $player.volume, in: 0...1).tint(pal.switchOn).frame(width: 235)
                        Text("\(Int(player.volume * 100))").font(Theme.font(12)).monospacedDigit().foregroundStyle(pal.muted).frame(width: 28)
                    }
                    MusicSettingRow(title: "播放顺序") {
                        HStack(spacing: 6) {
                            MusicChoice(title: "顺序", selected: !player.shuffle) { player.shuffle = false }
                            MusicChoice(title: "随机", selected: player.shuffle) { player.shuffle = true }
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    section("02", "界面", "APPEARANCE")
                    MusicSettingRow(title: "画质") {
                        HStack(spacing: 6) {
                            MusicChoice(title: "标准", selected: model.quality == .musicBalanced) { model.quality = .musicBalanced }
                            MusicChoice(title: "高清", selected: model.quality == .high) { model.quality = .high }
                        }
                    }
                    MusicSettingRow(title: "界面音效") {
                        HStack(spacing: 6) {
                            MusicChoice(title: "关闭", selected: !model.audioPrefs.sound) { model.audioPrefs.sound = false }
                            MusicChoice(title: "开启", selected: model.audioPrefs.sound) { model.audioPrefs.sound = true }
                        }
                    }
                    MusicSettingRow(title: "启动动画") {
                        Button("重播终端启动 ↗") { model.replay() }.buttonStyle(RhineButtonStyle())
                    }
                    MusicSettingRow(title: "动态效果") {
                        HStack(spacing: 6) {
                            MusicChoice(title: "完整", selected: !model.reduced) { model.reduced = false }
                            MusicChoice(title: "减弱", selected: model.reduced) { model.reduced = true }
                        }
                    }
                    MusicSettingRow(title: "静态呼吸") {
                        HStack(spacing: 6) {
                            MusicChoice(title: "开启", selected: model.idleDrift) { model.idleDrift = true }
                            MusicChoice(title: "关闭", selected: !model.idleDrift) { model.idleDrift = false }
                        }
                    }
                    Text("标准画质兼顾流畅与光影细节。")
                        .font(Theme.font(13)).foregroundStyle(pal.muted).padding(.top, 22)
                }.frame(maxWidth: .infinity)
            }.padding(.top, 18)
            Spacer()
            Text("设置会自动保存。")
                .font(Theme.font(13)).foregroundStyle(pal.muted).padding(.bottom, 26)
        }
    }
    private func section(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(number).font(Theme.font(12)).foregroundStyle(pal.muted)
            Text(title).font(Theme.font(25, .light))
            Spacer()
            Text(subtitle).font(Theme.font(10)).tracking(1).foregroundStyle(pal.muted)
        }.padding(.bottom, 20).overlay(alignment: .bottom) { MusicRule() }
    }
}
