import SwiftUI

struct RootView: View {

    @Environment(\.palette) private var pal
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 1920, geo.size.height / 1080)
            let _ = { model.windowSize = geo.size }()
            ZStack {
                // The 3D view fills the whole window; only the interface keeps its 16:9 stage.
                ArchiveSceneView(view: model.sceneView)
                DarkAtmosphere().opacity(model.dark && !model.viewerOpen ? 1 : 0).allowsHitTesting(false)
                Stage()
                    .frame(width: 1920, height: 1080)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: 1920 * scale, height: 1080 * scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(pal.paper)
        .environment(\.palette, model.dark ? .dark : .light)
        .animation(.easeInOut(duration: 0.85), value: model.dark)
    }
}

/// Dark theme: the array's far edges melt into the page at the top and bottom (web `.archive-atmosphere`).
private struct DarkAtmosphere: View {
    @Environment(\.palette) private var pal
    var body: some View {
        let paper = Palette.dark.paper
        ZStack {
            LinearGradient(stops: [.init(color: paper, location: 0), .init(color: paper.opacity(0.82), location: 0.11),
                                   .init(color: paper.opacity(0), location: 0.40)], startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: paper.opacity(0.94), location: 0), .init(color: paper.opacity(0), location: 0.19)],
                           startPoint: .bottom, endPoint: .top)
        }
    }
}

/// The 1920 × 1080 interface layer drawn over the 3D scene.
struct Stage: View {
    @EnvironmentObject var model: AppModel
    private let ease = Animation.easeOut(duration: 0.45)

    var body: some View {
        ZStack {
            Group {
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
            }
            // The object study covers the terminal; the page underneath stays mounted, only hidden.
            .opacity(model.viewerOpen ? 0 : 1)
            .allowsHitTesting(!model.viewerOpen)
            if model.viewerOpen { ViewerView().transition(.opacity) }
            ModalHost()
            Toast()
        }
        .animation(.easeOut(duration: model.viewerOpen ? 0.32 : 0.22), value: model.viewerOpen)
        .animation(ease, value: model.mode)
        .animation(ease, value: model.modal)
        .animation(ease, value: model.toast)
    }
}

/// "ENTER SYSTEM ↗" shown while the opening plays; dim until hovered.
private struct SkipButton: View {
    @Environment(\.palette) private var pal
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
        .foregroundStyle(pal.ink)
        .opacity(hovering ? 1 : 0.55)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}
