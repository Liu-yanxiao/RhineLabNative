import XCTest
import simd
@testable import RhineLab

final class WatermarkTests: XCTestCase {
    func testBackgroundLogoDoesNotShowThroughFoggedCards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let renderer = try XCTUnwrap(MetalRenderer(modelDirectory: root.appendingPathComponent("Resources/Models")))
        renderer.renderQuality = .performance
        let engine = ArchiveEngine(); engine.targetReveal = 1; engine.idleDrift = false
        for i in 0..<360 { engine.tick(time: Double(i) / 60, dt: 1.0 / 60) }
        engine.setDetail(true, time: 6)
        for i in 360..<840 { engine.tick(time: Double(i) / 60, dt: 1.0 / 60) }
        var frame = engine.makeFrame(aspect: 16.0 / 9.0)
        frame.arrayCards = []; frame.arrayPrints = []; frame.arrayLabels = []
        frame.cards[0].quality = 0
        frame.fogNear = 1; frame.fogFar = 2
        let matrix = frame.proj * frame.view, card = frame.cards[0]
        func project(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let clip = matrix * SIMD4(card.position + SIMD3(x, y, 0.26), 1)
            return SIMD2((clip.x / clip.w + 1) * 480, (1 - clip.y / clip.w) * 270)
        }
        let quad = [project(-1.6, 0.7), project(1.6, 0.7), project(1.6, 3), project(-1.6, 3)]
        let center = project(0, 1.85)
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 960 * 540 * 4)
            let context = CGContext(data: &bytes, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 960 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 960, height: 540))
            return bytes
        }
        let clean = pixels(try XCTUnwrap(ShotMode.capture(renderer, frame, width: 960, height: 540)))
        frame.watermark = SIMD4(center.x / 960, center.y / 540, 0.9, 0.8)
        frame.watermarkBehindScene = true
        let marked = pixels(try XCTUnwrap(ShotMode.capture(renderer, frame, width: 960, height: 540)))
        var coveredChanges = 0, totalChanges = 0
        for y in 0..<540 { for x in 0..<960 {
            let index = (y * 960 + x) * 4
            guard (0..<3).contains(where: { abs(Int(clean[index + $0]) - Int(marked[index + $0])) > 2 }) else { continue }
            totalChanges += 1
            let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
            let crosses = (0..<4).map { i -> Float in
                let a = quad[i], b = quad[(i + 1) % 4]
                return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            }
            if crosses.allSatisfy({ $0 >= 0 }) || crosses.allSatisfy({ $0 <= 0 }) { coveredChanges += 1 }
        } }
        print("logo changed \(coveredChanges) covered pixels, \(totalChanges) total pixels")
        XCTAssertGreaterThan(totalChanges, 30, "the logo must remain visible on the actual background")
        XCTAssertEqual(coveredChanges, 0, "fog must not lift the background logo above a solid card")
    }
}
