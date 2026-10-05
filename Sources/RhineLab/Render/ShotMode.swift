import Foundation
import Metal
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Headless rendering: `RhineLab --shot out.png [--detail] [--viewer [--exploded] [--frosted]] [--dark]
/// [--index N] [--size 1920x1080] [--ui MODE]`.
/// Runs the simulation forward, renders one frame offscreen and writes a PNG. With `--ui` the
/// SwiftUI interface for MODE (archive, detail, viewer, viewer-exploded, viewer-frosted, search,
/// saved, settings, boot) is composited over the scene so screenshots show the whole terminal.
enum ShotMode {
    static func run(_ args: [String]) {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--overlay-test") {
            let engine = ArchiveEngine(); engine.idleDrift = false; engine.targetReveal = 1
            engine.select(0, time: 0)
            var t = 0.0
            func adv(_ s: Double) { for _ in 0..<Int(s * 60) { t += 1.0 / 60; engine.tick(time: t, dt: 1.0 / 60) } }
            adv(5); engine.setDetail(true, time: t)
            for _ in 0..<14 {
                adv(0.4)
                let o = engine.overlay(aspect: 16.0 / 9.0)
                print(String(format: "t=%.1f phase=%@ lines=%d markers=%.2f label=%.2f clarity=%.2f doc=%.2f active=%d", t - 5, "\(o.frame.phase)", o.segments.count, o.frame.markers, o.frame.label, o.frame.clarity, o.documentProgress, o.active ? 1 : 0), o.segments.first.map { "\($0.0) → \($0.1)" } ?? "")
            }
            return
        }
        if args.contains("--bench") { bench(args); return }
        guard let path = value("--shot") else { return }
        let index = Int(value("--index") ?? "0") ?? 0
        let dims = (value("--size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (dims.first ?? 1920, dims.count > 1 ? dims[1] : 1080)
        let dark = args.contains("--dark")

        Theme.registerFonts()
        if let mode = value("--ui") {
            let bootTime = Double(value("--time") ?? "") ?? 8
            MainActor.assumeIsolated {
                shotWithInterface(path: path, mode: mode, index: index, dark: dark, width: w, height: h, bootTime: bootTime)
            }
            return
        }

        let detail = args.contains("--detail")
        let viewerShot = args.contains("--viewer")
        guard let renderer = MetalRenderer(compositeFormat: .bgra8Unorm) else {
            FileHandle.standardError.write(Data("no Metal renderer\n".utf8)); return
        }
        let engine = ArchiveEngine()
        engine.idleDrift = false
        engine.targetReveal = 1
        engine.setTheme(dark: dark, time: 0, immediate: true)
        engine.select(index, time: 0)
        var t = 0.0
        func advance(_ seconds: Double) {
            for _ in 0..<Int(seconds * 60) { t += 1.0 / 60; engine.tick(time: t, dt: 1.0 / 60) }
        }
        advance(6)
        if detail || viewerShot { engine.setDetail(true, time: t); advance(8) }
        var frame = engine.makeFrame(aspect: Float(w) / Float(h))
        if viewerShot {
            let viewer = ViewerEngine()
            viewer.theme = dark ? 1 : 0
            viewer.open(labelIndex: index)
            if args.contains("--exploded") { viewer.setExploded(true) }
            if args.contains("--frosted") { viewer.setClear(false) }
            var vt = 0.0
            for _ in 0..<(4 * 60) { vt += 1.0 / 60; viewer.tick(time: vt, dt: 1.0 / 60) }
            frame = viewer.makeFrame(aspect: Float(w) / Float(h))
        }
        guard let image = capture(renderer, frame, width: w, height: h) else { return }
        write(image, to: path)
    }

    /// Renders `frame` twice: the first pass requests any printed label still being built.
    private static func capture(_ renderer: MetalRenderer, _ frame: RenderFrame, width w: Int, height h: Int) -> CGImage? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: desc) else { return nil }
        for pass in 0..<2 {
            let done = DispatchSemaphore(value: 0)
            renderer.render(frame, to: target) { done.signal() }
            done.wait()
            if pass == 0 { Thread.sleep(forTimeInterval: 1.0) }
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA → RGBA for ImageIO.
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path)
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("wrote \(path) (\(image.width)x\(image.height))")
        }
    }

    /// Scene plus the SwiftUI stage, drawn with ImageRenderer and composited in software.
    @MainActor
    private static func shotWithInterface(path: String, mode: String, index: Int, dark: Bool, width w: Int, height h: Int, bootTime: Double) {
        AppModel.headless = true
        let model = AppModel()
        model.dark = dark
        model.engine.idleDrift = false
        if mode == "boot" { model.setBootTime(bootTime) }
        var t = CACurrentMediaTime()
        func advance(_ seconds: Double) {
            for _ in 0..<Int(seconds * 60) { t += 1.0 / 60; model.engine.tick(time: t, dt: 1.0 / 60) }
        }
        if mode != "boot" {
            model.finishBoot()
            model.select(index)
            advance(6)
        }
        if ["detail", "viewer", "viewer-exploded", "viewer-frosted"].contains(mode) {
            model.open()
            advance(8)
        }
        if mode.hasPrefix("viewer") {
            model.openViewer()
            if mode == "viewer-exploded" { model.setViewerExploded(true) }
            if mode == "viewer-frosted" { model.setViewerClear(false) }
            var vt = t
            for _ in 0..<(4 * 60) { vt += 1.0 / 60; model.viewer.tick(time: vt, dt: 1.0 / 60) }
        }
        switch mode {
        case "search": model.present(.search)
        case "saved": model.present(.saved)
        case "settings": model.present(.settings)
        default: break
        }

        let aspect = Float(w) / Float(h)
        let frame = model.viewerOpen ? model.viewer.makeFrame(aspect: aspect) : model.engine.makeFrame(aspect: aspect)
        guard let scene = capture(model.sceneView.renderer, frame, width: w, height: h) else { return }

        let stage = Stage()
            .environmentObject(model)
            .environment(\.palette, dark ? .dark : .light)
            .frame(width: 1920, height: 1080)
        let renderer = ImageRenderer(content: stage)
        renderer.scale = CGFloat(w) / 1920
        renderer.isOpaque = false
        guard let interface = renderer.cgImage else { FileHandle.standardError.write(Data("no interface image\n".utf8)); return }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(scene, in: rect)
        ctx.draw(interface, in: rect)
        if let image = ctx.makeImage() { write(image, to: path) }
    }

    /// `RhineLab --bench [WxH]`: GPU time per frame while the archive transitions into the detail view.
    static func bench(_ args: [String]) {
        let dims = (args.firstIndex(of: "--bench").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "2880x1620")
            .split(separator: "x").compactMap { Int($0) }
        let (w, h) = (dims.first ?? 2880, dims.count > 1 ? dims[1] : 1620)
        Theme.registerFonts()
        guard let renderer = MetalRenderer(compositeFormat: .bgra8Unorm) else { return }
        renderer.statsEnabled = true
        renderer.passTimingEnabled = true
        let engine = ArchiveEngine()
        engine.idleDrift = false
        engine.targetReveal = 1
        engine.select(0, time: 0)
        var t = 0.0
        func advance(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { t += 1.0 / 60; engine.tick(time: t, dt: 1.0 / 60) } }
        advance(5)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .private
        let target = renderer.device.makeTexture(descriptor: desc)!
        Thread.sleep(forTimeInterval: 1) // let label textures finish
        func run(_ label: String, frames: Int) {
            _ = renderer.drainGPUTimes()
            let done = DispatchSemaphore(value: 0)
            for _ in 0..<frames {
                t += 1.0 / 120; engine.tick(time: t, dt: 1.0 / 120)
                renderer.render(engine.makeFrame(aspect: Float(w) / Float(h)), to: target) { done.signal() }
                done.wait()
            }
            let g = renderer.drainGPUTimes().sorted()
            let mean = g.reduce(0, +) / Double(max(1, g.count))
            print(String(format: "%@ %dx%d: gpu mean %.2f  p95 %.2f  max %.2f ms", label, w, h, mean, g[Int(Double(g.count) * 0.95)], g.last ?? 0), "|", renderer.passTimingReport())
        }
        run("archive (settled)", frames: 60)
        engine.setDetail(true, time: t)
        run("detail transition", frames: 240)
        run("detail (settled)", frames: 60)
    }
}
