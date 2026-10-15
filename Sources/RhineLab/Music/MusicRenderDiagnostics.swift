import AppKit
import simd

enum MusicRenderDiagnostics {
    @MainActor static func run() async -> Bool {
        AppModel.headless = true
        let model = AppModel()
        model.sceneView.frame = CGRect(x: 0, y: 0, width: 1440, height: 810)
        model.sceneView.layout()
        let size = model.sceneView.renderedSize
        let resolution = size.width / 2880
        let engine = model.engine
        var time = CACurrentMediaTime()
        func advance(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { time += 1.0 / 60; engine.tick(time: time, dt: 1.0 / 60) } }
        advance(8); model.open(); advance(1.4)
        let before = engine.makeFrame(aspect: 16.0 / 9.0)
        let p = before.cards[0].position + SIMD3<Float>(0.14, 1.85, 0.15)
        func project(_ frame: RenderFrame, _ point: SIMD3<Float>) -> SIMD2<Float> {
            let viewProjection = frame.proj * frame.view
            let clip = viewProjection * SIMD4<Float>(point, 1)
            return SIMD2((clip.x / clip.w + 1) * 720, (1 - clip.y / clip.w) * 405)
        }
        try? await Task.sleep(for: .milliseconds(1450))
        let after = model.viewer.isOpen ? model.viewer.makeFrame(aspect: 16.0 / 9.0) : engine.makeFrame(aspect: 16.0 / 9.0)
        let afterPoint = model.viewer.isOpen ? SIMD3<Float>(0.14, 0, 0.15) : after.cards[0].position + SIMD3<Float>(0.14, 1.85, 0.15)
        let jump = simd_distance(project(before, p), project(after, afterPoint))
        print(String(format: "drawable %.0fx%.0f; native-pixel ratio %.3f; entry center jump %.1f pt", size.width, size.height, resolution, jump))
        let clear = resolution >= 0.99, continuous = jump <= 16
        print("\(clear ? "PASS" : "FAIL") native resolution; \(continuous ? "PASS" : "FAIL") continuous entry")
        return clear && continuous
    }
}
