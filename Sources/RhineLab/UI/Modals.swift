import SwiftUI
import AppKit

/// Archive index, saved list and settings, presented over a blurred backdrop.
struct ModalHost: View {
    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel

    // 300 ms in with a 12 pt rise, 200 ms out with an 8 pt drop.
    private static let panelIn = AnyTransition.opacity.combined(with: .offset(y: 12)).animation(.easeOut(duration: 0.3))
    private static let panelOut = AnyTransition.opacity.combined(with: .offset(y: 8)).animation(.easeIn(duration: 0.2))

    var body: some View {
        ZStack {
            if let modal = model.modal {
                Rectangle().fill(pal.paper.opacity(model.dark ? 0.6 : 0.45))
                    .background(.ultraThinMaterial)
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissModal() }
                    .transition(.opacity)
                Group {
                    switch modal {
                    case .search: DirectoryPanel(savedOnly: false)
                    case .saved: DirectoryPanel(savedOnly: true)
                    case .settings: SettingsPanel()
                    }
                }
                .transition(.asymmetric(insertion: Self.panelIn, removal: Self.panelOut))
            }
        }
    }
}

// MARK: Frame

/// The dialog sheet: top bar with the close button, then the panel's own content.
private struct ModalFrame<Content: View>: View {
    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel
    let label: String
    var width: CGFloat = 1260
    var height: CGFloat? = 836
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                Spacer()
                Button { model.dismissModal() } label: {
                    HStack(spacing: 24) { Text("CLOSE").font(Theme.font(10)); CloseGlyph() }
                }.buttonStyle(.plain)
            }
            .font(Theme.font(11)).tracking(1)
            .padding(.top, 35).padding(.bottom, 20)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
            content
        }
        .padding(.horizontal, 53)
        .padding(.bottom, height == nil ? 35 : 0)
        .frame(width: width, height: height, alignment: .top)
        .foregroundStyle(pal.ink)
        .background(pal.panel.opacity(0.97))
        .overlay(Rectangle().stroke(pal.panelEdge, lineWidth: 1))
        .shadow(color: pal.shadow, radius: 47, y: 26)
    }
}

private struct ModalTitle: View {

    @Environment(\.palette) private var pal
    let title: String
    let subtitle: String
    var size: CGFloat = 38

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 23) {
            Text(title).font(Theme.font(size, .bold)).tracking(-0.6)
            Text(subtitle).font(Theme.font(15)).tracking(2).foregroundStyle(pal.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 32).padding(.bottom, 29)
    }
}

private struct ModalFooter: View {

    @Environment(\.palette) private var pal
    let left: String
    let right: AnyView

    var body: some View {
        HStack { Text(left); Spacer(); right }
            .font(Theme.font(9)).tracking(1).foregroundStyle(pal.muted)
    }
}

// MARK: Archive directory (search and saved list)

private struct DirectoryRow: View {

    @Environment(\.palette) private var pal
    let record: ArchiveRecord
    let saved: Bool
    let highlighted: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 0) {
                HStack(spacing: 25) {
                    Text(record.id).font(Theme.font(14)).frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(record.title).font(Theme.font(16))
                        Text(record.en).font(Theme.font(9)).tracking(0.7)
                            .foregroundStyle(pal.muted).padding(.top, 7)
                    }
                    if saved { Text("＋").font(Theme.font(13)).foregroundStyle(pal.accent) }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 24)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(record.department).font(Theme.font(12)).foregroundStyle(pal.muted)
                    .frame(width: 230, alignment: .leading)

                HStack(spacing: 12) {
                    Text(record.clearance == "RESTRICTED" ? "CATALOG ONLY" : "AUTHORIZED")
                        .font(Theme.font(9)).tracking(0.5).foregroundStyle(pal.muted)
                    Spacer(minLength: 0)
                    Text("↗").font(Theme.font(24)).foregroundStyle(pal.ink)
                }
                .padding(.trailing, 30)
                .frame(width: 175)
            }
            .padding(.trailing, 7)
            .frame(minHeight: 76)
            .background((hovering || highlighted) ? pal.field : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.ink)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: hovering)
    }
}

/// "Archive index" and "Saved archives" share one layout; the latter lists only saved files.
private struct DirectoryPanel: View {
    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel
    let savedOnly: Bool
    @State private var query = ""
    @State private var filter = "全部档案"
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private var results: [ArchiveRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.records.filter { r in
            if savedOnly && !model.saved.contains(r.id) { return false }
            if filter != "全部档案" && r.category != filter { return false }
            if q.isEmpty { return true }
            let fields: [String] = [r.id, r.title, r.en, r.department, r.lead, r.category]
            return fields.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        let list = results
        ModalFrame(label: "RHINE LAB / ARCHIVE DIRECTORY") {
            ModalTitle(title: savedOnly ? "SAVED ARCHIVES" : "ARCHIVE INDEX", subtitle: savedOnly ? "收藏档案" : "内部档案检索")

            // Search field
            HStack(spacing: 22) {
                MagnifierGlyph(size: 26)
                ZStack(alignment: .leading) {
                    if query.isEmpty {
                        Text("输入档案编号、名称或科室").font(Theme.font(17)).tracking(0.5)
                            .foregroundStyle(pal.muted).allowsHitTesting(false)
                    }
                    TextField("", text: $query)
                        .textFieldStyle(.plain).font(Theme.font(19)).foregroundStyle(pal.ink)
                        .focused($focused)
                        .onSubmit { if list.indices.contains(cursor) { pick(list[cursor]) } }
                        .onChange(of: query) { _, _ in cursor = 0 }
                        .onKeyPress(.upArrow) { cursor = max(0, cursor - 1); return .handled }
                        .onKeyPress(.downArrow) { cursor = min(max(0, list.count - 1), cursor + 1); return .handled }
                }
                KeyCap(label: "ESC", width: 37, height: 24).padding(.trailing, 4)
            }
            .frame(height: 61)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.ink).frame(height: 2) }

            // Category filters
            HStack(spacing: 27) {
                ForEach(Archive.categories, id: \.self) { c in
                    Button { filter = c; cursor = 0 } label: {
                        HStack(spacing: 7) {
                            Rectangle().frame(width: 4, height: 4).opacity(filter == c ? 1 : 0)
                            Text(c).font(Theme.font(12))
                        }
                        .foregroundStyle(filter == c ? pal.ink : pal.muted)
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 25).padding(.bottom, 24)
            .animation(.easeOut(duration: 0.2), value: filter)

            // Column header
            HStack(spacing: 0) {
                Text("FILE / 档案").frame(maxWidth: .infinity, alignment: .leading)
                Text("DEPARTMENT / 科室").frame(width: 230, alignment: .leading)
                Text("ACCESS").frame(width: 175, alignment: .leading)
            }
            .font(Theme.font(9)).tracking(1).foregroundStyle(pal.muted)
            .padding(.vertical, 14).padding(.trailing, 7)
            .overlay(alignment: .top) { Rectangle().fill(pal.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                            DirectoryRow(record: r, saved: model.saved.contains(r.id), highlighted: i == cursor) { pick(r) }
                        }
                    }
                }
                .overlay { if list.isEmpty { emptyState } }
                .frame(height: 387)
                .onChange(of: cursor) { _, c in if list.indices.contains(c) { proxy.scrollTo(list[c].id) } }
            }

            Spacer(minLength: 0)
            ModalFooter(
                left: String(format: "%02d RECORDS FOUND", list.count),
                right: AnyView(HStack(spacing: 0) {
                    Text("INTERNAL DATABASE")
                    Text("●").font(Theme.font(8)).foregroundStyle(Color(hex: 0x858a6b)).padding(.horizontal, 8)
                    Text("CONNECTED")
                })
            ).padding(.bottom, 30)
        }
        .onAppear { focused = true }
    }

    private var emptyState: some View {
        let bare = savedOnly && query.isEmpty && filter == "全部档案"
        return VStack(spacing: 0) {
            Text("∅").font(Theme.font(44, .light)).foregroundStyle(pal.muted)
            Text(bare ? "尚无收藏档案" : "没有匹配的档案").font(Theme.font(18)).padding(.top, 20)
            Text(bare ? "读取档案时，选择 SAVE ARCHIVE 将其保存在此处。" : "尝试其他名称、档案编号，或切换科室分类。")
                .font(Theme.font(13)).foregroundStyle(pal.muted).padding(.top, 15).padding(.bottom, 25)
            if !bare {
                Button { query = ""; filter = "全部档案"; cursor = 0 } label: {
                    Text(savedOnly ? "查看全部收藏 →" : "重置检索 →").font(Theme.font(12)).padding(.bottom, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
                }.buttonStyle(.plain)
            }
        }
    }

    private func pick(_ r: ArchiveRecord) {
        model.dismissModal()
        if let i = model.records.firstIndex(of: r) { model.select(i) }
    }
}

// MARK: Settings

private struct SettingRow: View {

    @Environment(\.palette) private var pal
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    Text(title).font(Theme.font(12)).tracking(0.8)
                    Text(hint).font(Theme.font(12)).foregroundStyle(pal.muted)
                }
                Spacer()
                SquareSwitch(isOn: isOn)
            }
            .padding(.vertical, 17)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pal.ink)
    }
}

private struct Shortcut: View {

    @Environment(\.palette) private var pal
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 9) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(Theme.font(9)).padding(5)
                    .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
            }
            Text(label)
        }
    }
}

private struct SettingsPanel: View {

    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel

    var body: some View {
        ModalFrame(label: "RHINE LAB / SYSTEM PREFERENCES", width: 1080, height: nil) {
            if AppModel.headless {
                settingsContent
            } else {
                ScrollView(showsIndicators: false) { settingsContent }.frame(maxHeight: 900)
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            ModalTitle(title: "SYSTEM SETTINGS", subtitle: "终端偏好设置", size: 33)

            HStack(spacing: 18) { Text("JOYCE MOORE"); Text("·"); Text("SESSION AUTHORIZED") }
                .font(Theme.font(10)).tracking(1).foregroundStyle(pal.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)

            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("界面配色").font(Theme.font(14))
                        Text("玻璃阵列随配色逐张过渡").font(Theme.font(12)).foregroundStyle(pal.muted)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        ThemeChoice(label: "亮色", pressed: !model.dark) { model.dark = false }
                        ThemeChoice(label: "暗色", pressed: model.dark) { model.dark = true }
                    }
                }
                .padding(.vertical, 16)
                .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
                SettingRow(title: "SUPER PERFORMANCE", hint: "降低三维画质和渲染分辨率，保留完整动效；关闭后恢复原画质", isOn: $model.superPerformance)
                HStack(alignment: .top, spacing: 32) {
                    AudioSetting(title: "INTERFACE SOUND", hint: "操作与启动音效", label: "音效音量",
                                 isOn: $model.audioPrefs.sound, volume: $model.audioPrefs.soundVolume)
                    AudioSetting(title: "BACKGROUND MUSIC", hint: "观测室 · 背景音乐", label: "音乐音量",
                                 isOn: $model.audioPrefs.music, volume: $model.audioPrefs.musicVolume)
                }
                SettingRow(title: "REDUCED MOTION", hint: "镜头与档案运动直接到位，降低 GPU 占用", isOn: $model.reduced)
                SettingRow(title: "IDLE DRIFT", hint: "停在档案阵列时保留缓慢起伏；关闭后画面静止时完全不渲染", isOn: $model.idleDrift)
            }
            .overlay(alignment: .top) { Rectangle().fill(pal.line).frame(height: 1) }

            QualitySection()

            VStack(alignment: .leading, spacing: 19) {
                Text("KEYBOARD CONTROLS").font(Theme.font(9)).tracking(1).foregroundStyle(pal.muted)
                HStack(spacing: 18) {
                    Shortcut(keys: ["←", "→"], label: "切列")
                    Shortcut(keys: ["↑", "↓"], label: "选档")
                    Shortcut(keys: ["ENTER"], label: "读取")
                    Shortcut(keys: ["/"], label: "检索")
                    Shortcut(keys: ["ESC"], label: "返回")
                }
                .font(Theme.font(11)).foregroundStyle(pal.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26)

            HStack {
                Button { NSApplication.shared.keyWindow?.toggleFullScreen(nil) } label: {
                    HStack(spacing: 20) { Text("FULLSCREEN"); Text("↗").font(Theme.font(20)) }
                }
                Spacer()
                Button { model.replay() } label: {
                    HStack(spacing: 20) { Text("REINITIALIZE SYSTEM"); Text("↻").font(Theme.font(20)) }
                }
            }
            .buttonStyle(.plain).font(Theme.font(11)).tracking(0.8)
            .padding(.top, 30)

            ModalFooter(left: "ANALYSIS OS / 1.0 · 使用 MiSans 字体（小米）", right: AnyView(Text("POWERED BY RHINE LAB")))
                .padding(.top, 28)
                .padding(.bottom, 4)
        }
    }
}

// MARK: Render quality

/// RENDER QUALITY: preset, the actual render size and the fine controls (web `quality-settings`).
private struct QualitySection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) private var pal
    @State private var advanced = false

    private var presetLabels: [String] {
        RenderQuality.Preset.allCases.map(\.label) + (model.quality.preset == nil ? ["自定义"] : [])
    }

    var body: some View {
        let q = model.quality
        let locked = model.superPerformance
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 30) {
                HStack(spacing: 18) {
                    Text("RENDER QUALITY").tracking(0.8)
                    Text("渲染画质").foregroundStyle(pal.muted)
                }
                .font(Theme.font(12))
                Spacer()
                CycleChoice(options: presetLabels, index: RenderQuality.Preset.allCases.firstIndex { $0 == q.preset } ?? 4) { i in
                    model.quality = RenderQuality.Preset.allCases[i % RenderQuality.Preset.allCases.count].quality
                }
                .disabled(locked).opacity(locked ? 0.5 : 1)
            }
            .padding(.top, 24)

            Text(model.qualitySummary).font(Theme.font(12)).foregroundStyle(pal.muted)
                .padding(.top, 12).padding(.bottom, 20)

            Button { withAnimation(.easeOut(duration: 0.2)) { advanced.toggle() } } label: {
                HStack(spacing: 16) {
                    Text(advanced ? "▾" : "▸").font(Theme.font(11))
                    Text("精细设置").font(Theme.font(13))
                    Text("清晰度 / 材质 / 阴影").font(Theme.font(11)).foregroundStyle(pal.muted)
                }
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(pal.line).frame(height: 1) }

            if advanced {
                VStack(spacing: 0) {
                    RangeControl(label: "渲染比例", hint: "相对屏幕像素，受密度上限限制；高比例改善细线",
                                 value: Double(q.scale), range: 50...200, step: 5) { model.quality.scale = Int($0) }
                    HStack(alignment: .top, spacing: 32) {
                        VStack(spacing: 0) {
                            ChoiceControl(label: "像素密度上限", hint: "控制高密度屏幕的原生像素倍率",
                                          options: ["1×", "1.5×", "2×", "3×"], index: [1, 1.5, 2, 3].firstIndex(of: q.pixelRatio) ?? 1) {
                                model.quality.pixelRatio = [1, 1.5, 2, 3][$0]
                            }
                            ChoiceControl(label: "抗锯齿", hint: "4× 多重采样平滑模型边缘", options: ["关闭", "MSAA 4×"],
                                          index: q.antialias ? 1 : 0) { model.quality.antialias = $0 == 1 }
                            ChoiceControl(label: "纹理过滤", hint: "改善倾斜视角下的标签细节",
                                          options: ["1×", "2×", "4×", "8×", "16×"], index: [1, 2, 4, 8, 16].firstIndex(of: q.anisotropy) ?? 4) {
                                model.quality.anisotropy = [1, 2, 4, 8, 16][$0]
                            }
                            ChoiceControl(label: "透明材质分辨率", hint: "控制盖板折射画面的清晰度",
                                          options: ["25%", "50%", "75%", "100%"], index: [0.25, 0.5, 0.75, 1].firstIndex(of: q.transmission) ?? 3) {
                                model.quality.transmission = [0.25, 0.5, 0.75, 1][$0]
                            }
                        }
                        VStack(spacing: 0) {
                            ChoiceControl(label: "阴影分辨率 · 阵列", hint: "更高分辨率保留更细的投影边缘",
                                          options: ["关闭", "1024", "2048", "4096"], index: [0, 1024, 2048, 4096].firstIndex(of: q.shadows) ?? 2) {
                                model.quality.shadows = [0, 1024, 2048, 4096][$0]
                            }
                            ChoiceControl(label: "环境遮蔽 · 阵列", hint: "采样越多，接缝暗部越细腻",
                                          options: ["关闭", "16 采样", "32 采样", "64 采样"], index: [0, 16, 32, 64].firstIndex(of: q.aoSamples) ?? 2) {
                                model.quality.aoSamples = [0, 16, 32, 64][$0]
                            }
                            ChoiceControl(label: "遮蔽分辨率 · 阵列", hint: "降低可减轻环境遮蔽的渲染负担",
                                          options: ["50%", "75%", "100%"], index: [0.5, 0.75, 1].firstIndex(of: q.aoResolution) ?? 2) {
                                model.quality.aoResolution = [0.5, 0.75, 1][$0]
                            }
                        }
                    }
                    RangeControl(label: "景深强度 · 阵列", hint: "抽取档案时的镜头虚化；0 关闭",
                                 value: Double(q.depthOfField), range: 0...150, step: 5) { model.quality.depthOfField = Int($0) }
                }
                .disabled(locked).opacity(locked ? 0.5 : 1)
            }

            Text("即时生效并自动保存。清晰度与材质设置同步至 360° 查看器。高渲染比例更适合静态观察；缓冲上限为 829 万像素，硬件限制时自动收敛。")
                .font(Theme.font(11)).lineSpacing(6).foregroundStyle(pal.muted)
                .padding(.top, 12).padding(.bottom, 18)
        }
        .foregroundStyle(pal.ink)
        .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
    }
}

/// A bordered field that cycles through its options on click (the web's native select).
private struct CycleChoice: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) private var pal
    let options: [String]
    let index: Int
    let select: (Int) -> Void

    var body: some View {
        Button {
            model.audio.play(.uiTick)
            select((index + 1) % max(1, options.count))
        } label: {
            HStack(spacing: 14) {
                Text(options.indices.contains(index) ? options[index] : "自定义").font(Theme.font(12))
                Spacer(minLength: 0)
                Text("↻").font(Theme.font(12)).foregroundStyle(pal.muted)
            }
            .padding(.vertical, 9).padding(.leading, 12).padding(.trailing, 10)
            .frame(width: 125)
            .background(pal.field)
            .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ChoiceControl: View {
    @Environment(\.palette) private var pal
    let label: String
    let hint: String
    let options: [String]
    let index: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(label).font(Theme.font(13))
                Text(hint).font(Theme.font(10)).lineSpacing(3).foregroundStyle(pal.muted)
            }
            Spacer(minLength: 0)
            CycleChoice(options: options, index: index, select: select)
        }
        .padding(.vertical, 15)
        .overlay(alignment: .top) { Rectangle().fill(pal.line).frame(height: 1) }
    }
}

/// Slider row; the value is committed when the drag ends so the renderer rebuilds once.
private struct RangeControl: View {
    @Environment(\.palette) private var pal
    let label: String
    let hint: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let commit: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        let shown = dragging ?? value
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(label).font(Theme.font(13))
                Text(hint).font(Theme.font(10)).foregroundStyle(pal.muted)
            }
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                Slider(value: Binding(get: { shown }, set: { dragging = $0 }), in: range, step: step) { editing in
                    if !editing, let v = dragging { commit(v); dragging = nil }
                }
                .tint(pal.switchOn)
                .frame(width: 250)
                Text("\(Int(shown))%").font(Theme.font(12)).frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 15)
        .overlay(alignment: .top) { Rectangle().fill(pal.line).frame(height: 1) }
    }
}

/// Toggle plus volume slider for one of the two audio buses (web `.audio-setting`).
private struct AudioSetting: View {
    @Environment(\.palette) private var pal
    let title: String
    let hint: String
    let label: String
    @Binding var isOn: Bool
    @Binding var volume: Float

    var body: some View {
        VStack(spacing: 0) {
            Button { isOn.toggle() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title).font(Theme.font(12)).tracking(0.8)
                        Text(hint).font(Theme.font(12)).foregroundStyle(pal.muted)
                    }
                    Spacer()
                    SquareSwitch(isOn: isOn)
                }
                .padding(.top, 20).padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 12) {
                Text(label).font(Theme.font(10)).foregroundStyle(pal.muted).fixedSize()
                Slider(value: $volume, in: 0...1).tint(pal.switchOn).frame(height: 22)
                Text("\(Int((volume * 100).rounded()))%").font(Theme.font(10)).frame(minWidth: 36, alignment: .trailing)
            }
            .padding(.top, 8).padding(.bottom, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.line).frame(height: 1) }
        }
        .foregroundStyle(pal.ink)
    }
}

private struct ThemeChoice: View {
    @Environment(\.palette) private var pal
    let label: String
    let pressed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.font(13))
                .frame(minWidth: 76, minHeight: 42)
                .foregroundStyle(pressed ? pal.onSolid : pal.ink)
                .background(pressed ? pal.solid : Color.clear)
                .overlay(Rectangle().stroke(pal.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Toast

struct Toast: View {

    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let message = model.toast {
            Text(message).font(Theme.font(14))
                .padding(.horizontal, 27).padding(.vertical, 15)
                .foregroundStyle(pal.onToast)
                .background(pal.toast)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 85)
                .transition(.opacity.combined(with: .offset(y: 15)))
        }
    }
}
