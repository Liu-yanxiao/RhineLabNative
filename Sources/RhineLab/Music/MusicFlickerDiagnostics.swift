import AppKit
import Metal

/// Measures repeated >=3/255 brightness reversals in consecutive real GPU frames.
/// This catches coplanar-material shimmer that coordinate-only animation tests miss.
enum MusicFlickerDiagnostics {
    @MainActor static func run(output: String) async -> Bool {
        AppModel.headless = true
        let model = AppModel(), engine = model.engine, renderer = model.sceneView.renderer
        let width = 1440, height = 810, regionWidth = 700, regionHeight = 400
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: desc) else { return false }
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        var time = 1_336_000.0
        engine.select(engine.selectedIndex, time: time)
        func advance(_ n: Int) { for _ in 0..<n { time += 1.0 / 60; engine.tick(time: time, dt: 1.0 / 60) } }
        engine.idleDrift = true
        var records: [[String: Any]] = []
        var passed = true
        let windows = CommandLine.arguments.contains("--flicker-long") ? 30 : 3
        for dark in [false, true] {
            engine.setTheme(dark: dark, time: time, immediate: true)
            advance(1200)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            var previous = [Int16](repeating: 0, count: regionWidth * regionHeight)
            var previousDelta = previous
            for window in 0..<windows {
                // Exercise the same steady breathing after hover and navigation settle.
                if window == 10 { engine.setHover(engine.pick(ndc: SIMD2(-0.3, -0.2), aspect: 16.0 / 9.0)?.cell); advance(180) }
                if window == 15 { engine.setHover(nil); engine.select(1, time: time); advance(600) }
                if window == 20 { engine.setDetail(true, time: time); advance(600); engine.setDetail(false, time: time); advance(1200) }
                var reversals = [Int](repeating: 0, count: previous.count)
                for i in 0..<240 {
                    advance(1)
                    let frame = engine.makeFrame(aspect: 16.0 / 9.0)
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        renderer.render(frame, to: target) { continuation.resume() }
                    }
                    target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    for y in 0..<regionHeight {
                        for x in 0..<regionWidth {
                            let p = y * regionWidth + x
                            let value = Int16(bytes[((y + 250) * width + x + 300) * 4 + 1])
                            let delta = value - previous[p], old = previousDelta[p]
                            if i > 1, abs(delta) >= 3, abs(old) >= 3, (delta < 0) != (old < 0) { reversals[p] += 1 }
                            previous[p] = value; previousDelta[p] = delta
                        }
                    }
                }
                let frequent = reversals.filter { $0 > 20 }.count
                // Allow isolated raster edge pixels, but reject a flickering material region.
                let ok = frequent <= 16
                passed = passed && ok
                records.append(["dark":dark, "window":window, "frequentPixels":frequent, "maxReversals":reversals.max() ?? 0, "pass":ok])
                print("\(ok ? "PASS" : "FAIL") \(dark ? "dark" : "light") window \(window): \(frequent) frequent pixels; max \(reversals.max() ?? 0)")
                fflush(stdout)
            }
            let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            if let image = ctx.makeImage() { ShotMode.write(image, to: output + (dark ? "/dark.png" : "/light.png")) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: .prettyPrinted) { try? data.write(to: URL(fileURLWithPath: output + "/frames.json")) }
        return passed
    }
}
