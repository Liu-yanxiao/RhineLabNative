import Foundation

/// Rendering controls, independent of lighting, materials and animation (web `render-quality.ts`).
struct RenderQuality: Equatable, Codable {
    var scale = 100                 // percent of the window's points
    var pixelRatio: Float = 1.5     // cap on the backing scale
    var antialias = true            // 4× MSAA
    var shadows = 2048              // shadow map size, 0 = off
    var aoSamples = 32              // 0 = off
    var aoResolution: Float = 1
    var depthOfField = 100          // percent of the original lens
    var transmission: Float = 1     // resolution of the capture the glass refracts
    var anisotropy = 16

    static let performance = RenderQuality(scale: 80, pixelRatio: 1, antialias: true, shadows: 1024, aoSamples: 0,
                                           aoResolution: 0.5, depthOfField: 0, transmission: 0.5, anisotropy: 4)
    static let original = RenderQuality()
    static let high = RenderQuality(scale: 125, pixelRatio: 2, antialias: true, shadows: 4096, aoSamples: 32,
                                    aoResolution: 1, depthOfField: 100, transmission: 1, anisotropy: 16)
    static let ultra = RenderQuality(scale: 150, pixelRatio: 2, antialias: true, shadows: 4096, aoSamples: 64,
                                     aoResolution: 1, depthOfField: 100, transmission: 1, anisotropy: 16)
    /// 超级性能模式: the lowest cost that keeps every motion.
    static let superPerformance = RenderQuality(scale: 60, pixelRatio: 1, antialias: false, shadows: 0, aoSamples: 0,
                                                aoResolution: 0.5, depthOfField: 0, transmission: 0.5, anisotropy: 4)

    enum Preset: String, CaseIterable {
        case performance, original, high, ultra
        var label: String {
            switch self { case .performance: "性能"; case .original: "原始"; case .high: "高"; case .ultra: "极高" }
        }
        var quality: RenderQuality {
            switch self { case .performance: .performance; case .original: .original; case .high: .high; case .ultra: .ultra }
        }
    }

    var preset: Preset? { Preset.allCases.first { $0.quality == self } }

    /// Full-size buffers are capped at 8 294 400 pixels (3840 × 2160).
    static let pixelBudget = 8_294_400
    static let superPixelBudget = 921_600

    static func load() -> RenderQuality {
        guard let data = UserDefaults.standard.data(forKey: "rhine-quality"),
              let q = try? JSONDecoder().decode(RenderQuality.self, from: data) else { return .original }
        return q
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "rhine-quality") }
    }
}
