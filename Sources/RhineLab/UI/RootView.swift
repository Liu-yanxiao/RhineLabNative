import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 1920, geo.size.height / 1080)
            let _ = { model.windowSize = geo.size }()
            ZStack {
                // The 3D view fills the whole window; only the interface keeps its 16:9 stage.
                ArchiveSceneView(view: model.sceneView)
                Stage()
                    .frame(width: 1920, height: 1080)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: 1920 * scale, height: 1080 * scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(Theme.paper)
    }
}

/// The 1920 × 1080 interface layer drawn over the 3D scene.
private struct Stage: View {
    @EnvironmentObject var model: AppModel
    private let ease = Animation.easeOut(duration: 0.45)

    var body: some View {
        ZStack {
            if model.mode == .boot { BootView().transition(.opacity) }
            BrandHeader().place(left: 59, top: 114)
            if model.mode != .boot {
                SystemNav().place(right: 59, top: 124).transition(.opacity)
                PoweredBy().transition(.opacity)
                SystemFooter().transition(.opacity)
            }
            if model.mode == .archive { ArchiveHUD().transition(.opacity) }
            if model.mode == .detail { DetailView().transition(.opacity.animation(.easeOut(duration: 0.5).delay(0.6))) }
            if model.mode == .boot { SkipButton().place(right: 60, top: 121).transition(.opacity) }
            ModalHost()
            Toast()
        }
        .animation(ease, value: model.mode)
        .animation(ease, value: model.modal)
        .animation(ease, value: model.toast)
    }
}

/// "ENTER SYSTEM ↗" shown while the opening plays; dim until hovered.
private struct SkipButton: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button { model.finishBoot() } label: {
            HStack(spacing: 28) {
                Text("ENTER SYSTEM").font(Theme.font(14)).tracking(1.1)
                Text("↗").font(Theme.font(23))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .opacity(hovering ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}
