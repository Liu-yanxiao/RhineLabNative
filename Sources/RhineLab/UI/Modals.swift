import SwiftUI

/// Search, saved list and settings, presented over a blurred backdrop.
struct ModalHost: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let modal = model.modal {
            ZStack {
                Rectangle().fill(Color(red: 0.89, green: 0.878, blue: 0.843).opacity(0.45))
                    .background(.ultraThinMaterial)
                    .onTapGesture { model.dismissModal() }
                Group {
                    switch modal {
                    case .search: SearchPanel()
                    case .saved: SavedPanel()
                    case .settings: SettingsPanel()
                    }
                }
                .frame(width: 860)
                .background(Color(red: 0.925, green: 0.917, blue: 0.894))
                .overlay(Rectangle().stroke(Color(red: 0.76, green: 0.74, blue: 0.69), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 40, y: 20)
            }
            .transition(.opacity)
        }
    }
}

private struct ModalTop: View {
    @EnvironmentObject var model: AppModel
    let title: String, subtitle: String
    var body: some View {
        HStack {
            HStack(spacing: 14) { Text(title).tracking(1); Text(subtitle).foregroundStyle(Theme.muted) }
            Spacer()
            Button { model.dismissModal() } label: {
                HStack(spacing: 14) { Text("ESC").font(Theme.font(10)); Text("✕").font(Theme.font(14)) }
            }.buttonStyle(.plain)
        }
        .font(Theme.font(11)).foregroundStyle(Theme.ink)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(red: 0.76, green: 0.74, blue: 0.69)).frame(height: 1) }
        .padding(.horizontal, 53).padding(.top, 40)
    }
}

private struct ResultRow: View {
    let record: ArchiveRecord
    let highlighted: Bool
    let pick: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 24) {
                Text(record.id).font(Theme.font(13)).tracking(1).frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(Theme.font(17))
                    Text(record.en).font(Theme.font(10)).tracking(0.8).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(record.category).font(Theme.font(11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 53).padding(.vertical, 13)
            .background((hovering || highlighted) ? Color.black.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink).onHover { hovering = $0 }
    }
}

private struct SearchPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter = "全部档案"
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private var results: [ArchiveRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.records.filter { r in
            (filter == "全部档案" || r.category == filter)
                && (q.isEmpty || [r.id, r.title, r.en, r.department, r.lead, r.category].contains { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            ModalTop(title: "ARCHIVE INDEX", subtitle: "档案索引")
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("输入编号、标题、科室或负责人", text: $query)
                    .textFieldStyle(.plain).font(Theme.font(20)).focused($focused)
                    .onSubmit { if list.indices.contains(cursor) { pick(list[cursor]) } }
                    .onChange(of: query) { _, _ in cursor = 0 }
                    .onKeyPress(.upArrow) { cursor = max(0, cursor - 1); return .handled }
                    .onKeyPress(.downArrow) { cursor = min(max(0, list.count - 1), cursor + 1); return .handled }
                Text("\(list.count) / \(model.records.count)").font(Theme.font(11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 53).padding(.vertical, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Archive.categories, id: \.self) { c in
                        Button { filter = c; cursor = 0 } label: {
                            Text(c).font(Theme.font(12)).padding(.horizontal, 14).padding(.vertical, 7)
                                .foregroundStyle(filter == c ? Color.white : Theme.ink)
                                .background(filter == c ? Theme.dark : Color.clear)
                                .overlay(Rectangle().stroke(Color(red: 0.72, green: 0.7, blue: 0.65), lineWidth: filter == c ? 0 : 1))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 53)
            }.padding(.bottom, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                            ResultRow(record: r, highlighted: i == cursor) { pick(r) }
                        }
                        if list.isEmpty {
                            Text("没有找到匹配的档案").font(Theme.font(14)).foregroundStyle(Theme.muted).padding(40)
                        }
                    }
                }
                .frame(height: 420)
                .onChange(of: cursor) { _, c in if list.indices.contains(c) { proxy.scrollTo(list[c].id) } }
            }
            Spacer().frame(height: 26)
        }
        .onAppear { focused = true }
    }

    private func pick(_ r: ArchiveRecord) {
        model.dismissModal()
        if let i = model.records.firstIndex(of: r) { model.select(i) }
    }
}

private struct SavedPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let list = model.records.filter { model.saved.contains($0.id) }
        VStack(spacing: 0) {
            ModalTop(title: "SAVED ARCHIVES", subtitle: "收藏档案")
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { r in
                        ResultRow(record: r, highlighted: false) {
                            model.dismissModal()
                            if let i = model.records.firstIndex(of: r) { model.select(i) }
                        }
                    }
                    if list.isEmpty {
                        Text("还没有收藏。在档案详情页点击 SAVE ARCHIVE 即可收藏。")
                            .font(Theme.font(14)).foregroundStyle(Theme.muted).padding(40)
                    }
                }
            }.frame(height: 360)
            Spacer().frame(height: 26)
        }
    }
}

private struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ModalTop(title: "SYSTEM SETTINGS", subtitle: "系统设置")
            VStack(alignment: .leading, spacing: 26) {
                toggle("减少动态效果", "镜头与档案运动直接到位，降低 GPU 占用", $model.reduced)
                toggle("待机微动", "停在档案阵列时保留缓慢起伏；关闭后画面静止时完全不渲染", $model.idleDrift)
            }.padding(.horizontal, 53).padding(.vertical, 34)
        }
    }
    private func toggle(_ title: String, _ hint: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.font(17))
                Text(hint).font(Theme.font(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }.foregroundStyle(Theme.ink)
    }
}

struct Toast: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let message = model.toast {
            Text(message).font(Theme.font(14))
                .padding(.horizontal, 27).padding(.vertical, 15)
                .foregroundStyle(Color(red: 0.945, green: 0.937, blue: 0.875))
                .background(Color(red: 0.188, green: 0.212, blue: 0.165))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 85)
                .transition(.opacity.combined(with: .offset(y: 15)))
        }
    }
}
