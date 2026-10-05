import SwiftUI

/// The independent object study: orbit the model, switch the glass, take the assembly apart.
/// Layout follows the web version's `.model-viewer` rules on the 1920 × 1080 stage.
struct ViewerView: View {
    @EnvironmentObject var model: AppModel
    @State private var settled = false
    private let ink = Color(hex: 0x20221c)

    var body: some View {
        ZStack(alignment: .topLeading) {
            header.place(left: 60, right: 60, top: 58).slide(settled)
            surfaceToggle.place(right: 62, top: 144)
            partsList.place(right: 70, top: 300)
            footer.place(left: 60, right: 60, bottom: 68).slide(settled)
            Text(model.viewerStatus).font(Theme.font(11)).tracking(1).foregroundStyle(Color(hex: 0x85806f))
                .frame(maxWidth: .infinity).place(bottom: 37).slide(settled)
        }
        .foregroundStyle(ink)
        .onAppear { withAnimation(.easeOut(duration: 0.3).delay(0.06)) { settled = true } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { model.closeViewer() } label: {
                HStack(spacing: 18) {
                    Text("←").font(Theme.font(22))
                    Text("返回档案").font(Theme.font(15))
                    Text("ESC").font(Theme.font(10)).padding(4).foregroundStyle(Color(hex: 0x817b70))
                        .overlay(Rectangle().stroke(Color(hex: 0xb8b3a9), lineWidth: 1)).padding(.leading, 8)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                Text("RHINE LAB / OBJECT STUDY").font(Theme.font(11)).tracking(1.8).foregroundStyle(Color(hex: 0x79766a))
                Text(model.record.title).font(Theme.font(31, .semibold)).padding(.top, 10).padding(.bottom, 8)
                Text("FILE \(model.record.id) / INTERNAL DATABASE").font(Theme.font(11)).tracking(1).foregroundStyle(Color(hex: 0x858073))
            }
            .padding(.leading, 74).padding(.top, 12)

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 0) {
                Text("360").font(Theme.font(58, .light))
                Text("°").font(Theme.font(32, .light))
            }
            .foregroundStyle(Color(hex: 0x6a6b5d))
        }
    }

    private var surfaceToggle: some View {
        HStack(spacing: 0) {
            SurfaceButton(label: "清晰", pressed: model.viewerClear) { model.setViewerClear(true) }
            Rectangle().fill(Color(hex: 0xbcb6ac)).frame(width: 1)
            SurfaceButton(label: "磨砂", pressed: !model.viewerClear) { model.setViewerClear(false) }
        }
        .fixedSize()
        .overlay(Rectangle().stroke(Color(hex: 0xbcb6ac), lineWidth: 1))
    }

    private var partsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ASSEMBLY / 装配结构").font(Theme.font(11)).tracking(1).foregroundStyle(Color(hex: 0x7e7a6d))
                .padding(.bottom, 24)
            ForEach(Array(ViewerEngine.parts.enumerated()), id: \.element.id) { i, part in
                ZStack(alignment: .topLeading) {
                    Text(String(format: "%02d", i + 1)).font(Theme.font(11)).foregroundStyle(Color(hex: 0x9b947f)).offset(y: 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(part.label).font(Theme.font(16))
                        Text(part.en).font(Theme.font(9)).tracking(1).foregroundStyle(Color(hex: 0x827b6c))
                    }
                    .padding(.leading, 38)
                }
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xcec9bc)).frame(height: 1) }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 230)
        .opacity(model.viewerExploded ? 1 : 0)
        .offset(x: model.viewerExploded ? 0 : 12)
        .animation(.easeOut(duration: 0.4), value: model.viewerExploded)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 18) { Text("拖动旋转"); Text("↑ ↓ ← → 平移"); Text("滚轮缩放") }
                .font(Theme.font(12)).foregroundStyle(Color(hex: 0x787568))
                .frame(width: 400, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ActionButton(glyph: "＋", label: "拆解档案", pressed: model.viewerExploded) { model.setViewerExploded(true) }
                ActionButton(glyph: "−", label: "一键重组", pressed: !model.viewerExploded) { model.setViewerExploded(false) }
            }
            .background(Color(hex: 0xe8e5e1))
            .overlay(Rectangle().stroke(Color(hex: 0xa4a08f), lineWidth: 1))
            Spacer(minLength: 0)
            Button { model.viewer.reset(animated: true) } label: {
                HStack(spacing: 18) { Text("复位视角"); Text("↗") }.font(Theme.font(14)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 400, alignment: .trailing)
        }
    }
}

private extension View {
    /// Header, footer and status rise 10 pt into place as the study opens.
    func slide(_ settled: Bool) -> some View {
        opacity(settled ? 1 : 0).offset(y: settled ? 0 : 10)
    }
}

private struct SurfaceButton: View {
    let label: String
    let pressed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.font(14))
                .padding(.horizontal, 22).padding(.vertical, 10)
                .foregroundStyle(pressed ? Color(hex: 0xf5f1e9) : Color(hex: 0x626158))
                .background(pressed ? Color(hex: 0x353b30) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: pressed)
    }
}

private struct ActionButton: View {
    let glyph: String
    let label: String
    let pressed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { Text(glyph); Text(label) }
                .font(Theme.font(15))
                .padding(.horizontal, 24).padding(.vertical, 19)
                .frame(minWidth: 166)
                .foregroundStyle(hovering ? Color(hex: 0x20221c) : (pressed ? Color(hex: 0xeeeade) : Color(hex: 0x20221c)))
                .background(hovering ? Color(hex: 0xc9c8b6) : (pressed ? Color(hex: 0x292d24) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.easeOut(duration: 0.2), value: pressed)
    }
}
