import Foundation
import simd
import Metal

/// Mirrors `SurfaceMat` in the shader.
struct SurfaceMat {
    var colorLow = SIMD4<Float>(1, 1, 1, 0.5)     // rgb, roughness
    var colorHigh = SIMD4<Float>(1, 1, 1, 0.5)
    var p0 = SIMD4<Float>(0, 0, 0, 0)            // metalLow, metalHigh, transmissionLow, transmissionHigh
    var p1 = SIMD4<Float>(0.1, 1e9, 1.46, 0)     // thickness, attenuation distance, ior, kind
    var atten = SIMD4<Float>(1, 1, 1, 1)
    var dark = SIMD4<Float>(0.5, 0.5, 0.5, 0)    // albedo under the dark theme
    var p2 = SIMD4<Float>(0, 0, 0, 0)            // clearcoat (array look), clearcoat roughness, array thickness, array attenuation distance
    var attenArray = SIMD4<Float>(1, 1, 1, 0)    // attenuation colour inside the array (w = 1 when set)
}

enum SurfaceKind: Float { case opaque = 0, frost = 1, internalPart = 2, floor = 3, ivory = 4 }

func srgbLinear(_ hex: UInt32) -> SIMD3<Float> {
    func c(_ v: UInt32) -> Float {
        let s = Float(v & 255) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return SIMD3(c(hex >> 16), c(hex >> 8), c(hex))
}

/// Tuning knobs read from the environment (`RL_*`) so looks can be swept without rebuilding.
enum Look {
    static func number(_ key: String, _ fallback: Float) -> Float {
        Float(ProcessInfo.processInfo.environment[key] ?? "") ?? fallback
    }
    static func hex(_ key: String, _ fallback: UInt32) -> UInt32 {
        guard let s = ProcessInfo.processInfo.environment[key], let v = UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) else { return fallback }
        return v
    }
    static func vector(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let parts = (ProcessInfo.processInfo.environment[key] ?? "").split(separator: ",").compactMap { Float($0) }
        return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : fallback
    }
}

enum Surfaces {
    /// Surfaces that exist in the array; everything else only appears on an extracted card.
    static let arraySurfaces: Set<String> = [
        "Frosted_Polymer", "Ivory_Edges", "Titanium_Fasteners", "Index_Inlay", "Optical_Diffuser",
    ]
    static let hidden: Set<String> = ["Carbon_Ink"]

    /// Dark-theme albedo per surface (web `theme-material.ts`).
    static let darkSurfaces: [String: UInt32] = [
        "Frosted_Polymer": 0x626b70, "Ivory_Edges": 0x687277, "Optical_Diffuser": 0x192226,
        "Titanium_Fasteners": 0xb1b9bb, "Index_Inlay": 0xc6a36b, "Printed_Label": 0x303a3e,
        "Subsurface_Optics": 0x939e9f, "Optical_Edges": 0xbbc3bc, "Carbon_Ink": 0xb6bdb8,
    ]
    static func darkColor(for name: String) -> SIMD3<Float> {
        srgbLinear(darkSurfaces[name] ?? (name.contains("Orange") ? 0xbb8850 : 0x969f9f))
    }

    static func material(for mesh: GLBMesh) -> (mat: SurfaceMat, kind: SurfaceKind) {
        var m = SurfaceMat()
        let glb = mesh.baseColor
        let rough = mesh.roughness, metal = mesh.metallic
        func set(low: SIMD3<Float>, rl: Float, high: SIMD3<Float>, rh: Float, metalLow: Float? = nil, metalHigh: Float? = nil) {
            m.colorLow = SIMD4(low, rl); m.colorHigh = SIMD4(high, rh)
            m.p0.x = metalLow ?? metal; m.p0.y = metalHigh ?? metal
        }
        var kind: SurfaceKind = Surfaces.arraySurfaces.contains(mesh.materialName) ? .opaque : .internalPart
        switch mesh.materialName {
        case "Frosted_Polymer":
            // Video look: inside the array the shell reads as a warm tan body; the extracted cover stays near-white.
            set(low: srgbLinear(Look.hex("RL_FROST", 0xe8dccc)), rl: 0.28, high: srgbLinear(0xfffdfa), rh: 0.21, metalLow: 0, metalHigh: 0)
            // Web `arrayMat`: transmission 0.78 with a light clearcoat; the extracted cover clears to 0.9.
            m.p0.z = 0.78; m.p0.w = 0.9
            m.p1 = SIMD4(0.12, 2, 1.46, 0)
            // Inside the array the body is thicker and tinted (video look): longer oblique paths pick up the warm tone.
            m.p2 = SIMD4(0.3, 0.25, Look.number("RL_THICK", 0.28), Look.number("RL_ATTEN_DIST", 0.25))
            m.atten = SIMD4(srgbLinear(0xeee6df), 1)
            m.attenArray = SIMD4(srgbLinear(Look.hex("RL_ATTEN", 0xe6dccc)), 1)
            kind = .frost
        case "Ivory_Edges":
            // Video look: the body plate is translucent and tinted like the cover (web keeps it opaque in the array).
            set(low: srgbLinear(Look.hex("RL_IVORY", 0xe8dccc)), rl: 0.38, high: srgbLinear(0xf0e7df), rh: 0.31, metalLow: 0, metalHigh: 0)
            m.p0.z = Look.number("RL_IVORY_T", 0.6); m.p0.w = 0.65
            m.p1 = SIMD4(0.04, 1e9, 1.46, 0)
            m.p2 = SIMD4(0, 0, Look.number("RL_THICK", 0.28), Look.number("RL_ATTEN_DIST", 0.25))
            m.attenArray = SIMD4(srgbLinear(Look.hex("RL_ATTEN", 0xe6dccc)), 1)
            kind = .ivory
        case "Optical_Diffuser":
            set(low: srgbLinear(0xa09484), rl: 0.7, high: srgbLinear(0xe2dad4), rh: 0.7, metalLow: 0, metalHigh: 0)
        case "Titanium_Fasteners":
            let c = simd_min(glb * 1.6, SIMD3<Float>(repeating: 0.95)); set(low: c, rl: 0.28, high: c, rh: 0.28, metalLow: 0.5, metalHigh: 0.5)
        case "Index_Inlay":
            set(low: srgbLinear(0xe4d6c5), rl: rough, high: glb, rh: rough, metalLow: 0.05, metalHigh: metal)
        case "Internal_Ceramic":
            let c = srgbLinear(0xc7beb6); set(low: c, rl: 0.6, high: c, rh: 0.6)
        case "Printed_Label":
            let c = srgbLinear(0xeae5dc); set(low: c, rl: rough, high: c, rh: rough, metalLow: 0, metalHigh: 0)
        case "Subsurface_Optics":
            let c = srgbLinear(0xb9aba1); set(low: c, rl: 0.48, high: c, rh: 0.48, metalLow: 0.05, metalHigh: 0.05)
        case "Optical_Edges":
            let c = srgbLinear(0xd4c7be); set(low: c, rl: 0.26, high: c, rh: 0.26, metalLow: 0.08, metalHigh: 0.08)
        default:
            set(low: glb, rl: rough, high: glb, rh: rough)
        }
        m.p1.w = kind.rawValue
        m.dark = SIMD4(darkColor(for: mesh.materialName), 0)
        return (m, kind)
    }

    static var floor: SurfaceMat {
        var m = SurfaceMat()
        let c = srgbLinear(0xd8c9b9)
        m.colorLow = SIMD4(c, 0.95); m.colorHigh = SIMD4(c, 0.95)
        m.p1.w = SurfaceKind.floor.rawValue
        m.dark = SIMD4(srgbLinear(0x192125), 0)
        return m
    }
}

/// A mesh uploaded to the GPU (interleaved position, normal, uv).
struct GPUMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    let material: SurfaceMat
    let kind: SurfaceKind
    let name: String

    init(device: MTLDevice, positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>],
         indices: [UInt32], material: SurfaceMat, kind: SurfaceKind, name: String) {
        var data = [Float]()
        data.reserveCapacity(positions.count * 8)
        for i in 0..<positions.count {
            let n = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)
            let uv = i < uvs.count ? uvs[i] : SIMD2<Float>(0, 0)
            data += [positions[i].x, positions[i].y, positions[i].z, n.x, n.y, n.z, uv.x, uv.y]
        }
        vertices = device.makeBuffer(bytes: data, length: data.count * 4, options: .storageModeShared)!
        self.indices = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)!
        indexCount = indices.count
        self.material = material
        self.kind = kind
        self.name = name
    }

    init(device: MTLDevice, glb mesh: GLBMesh) {
        let (m, kind) = Surfaces.material(for: mesh)
        self.init(device: device, positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs,
                  indices: mesh.indices, material: m, kind: kind, name: mesh.materialName)
    }
}
