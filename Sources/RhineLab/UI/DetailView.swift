import SwiftUI

/// Reading view shown beside the extracted card.
struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @State private var viewerOpen = false

    var body: some View {
        let r = model.record
        ZStack(alignment: .topLeading) {
            Button { model.back() } label: {
                HStack(spacing: 20) {
                    Text("←").font(Theme.font(24))
                    Text("ARCHIVE OVERVIEW").font(Theme.font(12)).tracking(1)
                    Text("ESC").font(Theme.font(10)).foregroundStyle(Color(red: 0.53, green: 0.53, blue: 0.5))
                        .padding(4).overlay(Rectangle().stroke(Color(red: 0.72, green: 0.7, blue: 0.66), lineWidth: 1))
                        .padding(.leading, 18)
                }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.ink).place(left: 59, top: 289)

            // Caption under the card
            VStack(alignment: .leading, spacing: 0) {
                Text("NO." + String(format: "%03d", model.selected + 1)).font(Theme.font(37)).tracking(-1)
                    .contentTransition(.numericText())
                Text("INTERNAL DATABASE").font(Theme.font(10)).tracking(1.8)
                    .foregroundStyle(Color(red: 0.46, green: 0.45, blue: 0.416)).padding(.top, 7)
                HStack(spacing: 18) { Text("DRAG TO INSPECT"); Text("↔").font(Theme.font(18)) }
                    .font(Theme.font(10)).tracking(1).foregroundStyle(Color(red: 0.506, green: 0.482, blue: 0.439)).padding(.top, 34)
                ViewerOpenButton().padding(.top, 25)
            }
            .foregroundStyle(Theme.ink).place(left: 60, bottom: 235)

            InspectionOverlay()
            RedactionClock { progress in
                DetailContent(record: r, progress: progress).environmentObject(model)
                    .frame(width: 636, alignment: .topLeading)
            }
            .offset(x: 1154, y: 289)
        }
    }
}

/// Supplies the document redaction progress each frame until the text is readable.
private struct RedactionClock<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @State private var finished = false
    @ViewBuilder let content: (Float) -> Content
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: finished)) { _ in
            let p = model.engine.redactionProgress
            content(p).onChange(of: p >= 1) { _, done in if done { finished = true } }
        }
    }
}

private struct DetailContent: View {
    @EnvironmentObject var model: AppModel
    let record: ArchiveRecord
    let progress: Float
    private let tabs = ["概述", "研究记录", "访问日志"]
    @Namespace private var underline

    var body: some View {
        let r = record
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FILE \(r.id)").font(Theme.font(11)).tracking(1.4)
                Spacer()
                Text(r.clearance).font(Theme.font(9)).foregroundStyle(Color(red: 0.467, green: 0.459, blue: 0.42))
            }
            RedactedText(text: r.en, weight: .bold, size: 40, tracking: -1.3, width: 620, progress: progress, order: 0)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 30).padding(.bottom, 13)
            HStack(spacing: 23) {
                RedactedText(text: r.title, size: 23, progress: progress, order: 2)
                Text(r.category).font(Theme.font(11)).tracking(1).foregroundStyle(Color(red: 0.467, green: 0.455, blue: 0.416))
            }
            Rectangle().fill(Color(red: 0.125, green: 0.133, blue: 0.113)).frame(height: 2).padding(.top, 28)

            Grid(alignment: .leading, horizontalSpacing: 42, verticalSpacing: 25) {
                GridRow { meta("DEPARTMENT / 科室", r.department); meta("COLLECTION / 编目范围", r.date) }
                GridRow { meta("RELATED / 相关人物", r.lead); meta("STATUS / 状态", r.clearance == "RESTRICTED" ? "目录访问" : "已归档 · 可读取", dot: true) }
            }.padding(.top, 28).padding(.bottom, 34)

            // Tabs
            HStack(spacing: 34) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button { withAnimation(.easeOut(duration: 0.18)) { model.tab = i } } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", i + 1)).font(Theme.font(10))
                                Text(tabs[i]).font(Theme.font(15))
                            }
                            .foregroundStyle(model.tab == i ? Color(red: 0.1, green: 0.11, blue: 0.086) : Color(red: 0.6, green: 0.57, blue: 0.52))
                            .padding(.bottom, 14)
                            ZStack {
                                if model.tab == i {
                                    Rectangle().fill(Color(red: 0.145, green: 0.157, blue: 0.118)).frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }.frame(height: 2)
                        }
                        .fixedSize()
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(red: 0.74, green: 0.72, blue: 0.68)).frame(height: 1) }

            ScrollView(.vertical, showsIndicators: false) {
                panel(r).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 22)
            }
            .frame(height: 189)
            .id(r.id + String(model.tab))
            .transition(.opacity)

            HStack(spacing: 30) {
                Button { model.toggleSaved() } label: {
                    HStack {
                        Text(model.saved.contains(r.id) ? "− REMOVE FROM SAVED" : "＋ SAVE ARCHIVE").tracking(1)
                        Spacer()
                        Text(model.saved.contains(r.id) ? "已收藏" : "收藏档案").foregroundStyle(Color(red: 0.737, green: 0.749, blue: 0.694))
                    }
                    .font(Theme.font(11)).padding(.horizontal, 18).frame(height: 46)
                    .foregroundStyle(Color(red: 0.94, green: 0.933, blue: 0.898)).background(Theme.dark)
                }.buttonStyle(.plain)
                Button { model.export() } label: {
                    HStack { Text("EXPORT").tracking(1).font(Theme.font(11)); Spacer(); Text("↓").font(Theme.font(23)) }
                        .frame(width: 105, height: 46)
                }.buttonStyle(.plain)
            }.padding(.top, 19)

            HStack {
                Link("设定参考 ↗", destination: URL(string: r.source) ?? URL(string: "https://prts.wiki")!)
                Spacer()
                Text(String(format: "%03d / %03d", model.selected + 1, model.records.count))
            }
            .font(Theme.font(8)).tracking(0.6).foregroundStyle(Color(red: 0.604, green: 0.58, blue: 0.529)).padding(.top, 22)
        }
        .foregroundStyle(Theme.ink)
    }

    private func meta(_ label: String, _ value: String, dot: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Theme.font(11)).tracking(0.7).foregroundStyle(Color(red: 0.502, green: 0.482, blue: 0.439))
            HStack(spacing: 8) {
                if dot { Rectangle().fill(Color(red: 0.545, green: 0.561, blue: 0.459)).frame(width: 5, height: 5) }
                RedactedText(text: value, size: 17, progress: progress, order: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func panel(_ r: ArchiveRecord) -> some View {
        let body = Color(red: 0.353, green: 0.345, blue: 0.306)
        switch model.tab {
        case 0:
            VStack(alignment: .leading, spacing: 14) {
                label("ABSTRACT / 摘要")
                RedactedText(text: r.abstract, size: 18, lineSpacing: 7, width: 636, color: body, progress: progress, order: 6)
            }
        case 1:
            VStack(alignment: .leading, spacing: 8) {
                label("RESEARCH NOTES / 研究记录")
                ForEach(Array(r.findings.enumerated()), id: \.offset) { i, f in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(String(format: "%02d", i + 1)).font(Theme.font(10)).foregroundStyle(Color(red: 0.64, green: 0.557, blue: 0.447))
                        RedactedText(text: f, size: 16, lineSpacing: 5, width: 600, color: body, progress: progress, order: 6 + i * 2)
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                label("ACCESS LOG / 本次访问")
                ForEach(Array(model.accessLog.filter { $0.id == r.id }.prefix(4).enumerated()), id: \.offset) { _, e in
                    HStack {
                        Text(e.time); Spacer(); Text("JOYCE MOORE"); Spacer()
                        Text("READ AUTHORIZED").font(Theme.font(9)).foregroundStyle(Color(red: 0.478, green: 0.506, blue: 0.388))
                    }.font(Theme.font(10)).padding(.top, 21)
                }
                Text("本次会话已通过身份验证。档案内容以当前终端可访问范围展示。")
                    .font(Theme.font(16)).lineSpacing(6).foregroundStyle(body).padding(.top, 20)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(Theme.font(11)).tracking(1).foregroundStyle(Color(red: 0.533, green: 0.502, blue: 0.455))
    }
}

/// "360° 查看文档模型 ↗": opens the independent object study.
private struct ViewerOpenButton: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button { model.openViewer() } label: {
            HStack(spacing: 16) {
                Text("360° 查看文档模型").font(Theme.font(14)).tracking(0.3)
                Text("↗").font(Theme.font(20))
            }
            .padding(.top, 12).padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(hovering ? Color(hex: 0x946b3c) : Color(hex: 0x8e897b)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color(hex: 0x946b3c) : Theme.ink)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}
