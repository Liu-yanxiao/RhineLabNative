import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

/// Headless rendering: `RhineLab --shot out.png [--detail] [--index N] [--size 1920x1080]`.
/// Runs the simulation forward, renders one frame offscreen and writes a PNG.
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
        let detail = args.contains("--detail")
        let viewerShot = args.contains("--viewer")
        let index = Int(value("--index") ?? "0") ?? 0
        let dims = (value("--size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        let (w, h) = (dims.first ?? 1920, dims.count > 1 ? dims[1] : 1080)

        Theme.registerFonts()
        guard let renderer = MetalRenderer(compositeFormat: .bgra8Unorm) else {
            FileHandle.standardError.write(Data("no Metal renderer\n".utf8)); return
        }
        let engine = ArchiveEngine()
        engine.idleDrift = false
        engine.targetReveal = 1
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
            viewer.open(labelIndex: index)
            if args.contains("--exploded") { viewer.setExploded(true) }
            if args.contains("--frosted") { viewer.setClear(false) }
            var vt = 0.0
            for _ in 0..<(4 * 60) { vt += 1.0 / 60; viewer.tick(time: vt, dt: 1.0 / 60) }
            frame = viewer.makeFrame(aspect: Float(w) / Float(h))
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = renderer.device.makeTexture(descriptor: desc)!
        let done = DispatchSemaphore(value: 0)
        renderer.render(frame, to: target) { done.signal() }
        done.wait()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA → RGBA for ImageIO.
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let url = URL(fileURLWithPath: path)
        if let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("wrote \(path) (\(w)x\(h))")
        }
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
