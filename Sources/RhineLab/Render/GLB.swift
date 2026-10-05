import Foundation
import simd

/// One glTF primitive, with positions already baked into model space.
struct GLBMesh {
    let materialName: String       // trailing ".012" style suffix removed
    let part: String?              // assembly part from node extras
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let uvs: [SIMD2<Float>]
    let indices: [UInt32]
    let baseColor: SIMD3<Float>    // linear, from the glTF material
    let metallic: Float
    let roughness: Float
}

/// Minimal binary glTF reader: only what the two archive models use
/// (triangle primitives, float POSITION / NORMAL / TEXCOORD_0, no animation).
enum GLB {
    enum LoadError: Error { case malformed(String) }

    static func load(resource: String) throws -> [GLBMesh] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "glb") else {
            throw LoadError.malformed("missing \(resource).glb")
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> [GLBMesh] {
        func u32(_ o: Int) -> Int {
            Int(data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        guard data.count > 20, u32(0) == 0x4654_6C67 else { throw LoadError.malformed("not a GLB") }
        let jsonLength = u32(12)
        let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<20 + jsonLength)) as! [String: Any]
        let binHeader = 20 + jsonLength
        let binStart = binHeader + 8
        let bin = data.subdata(in: binStart..<binStart + u32(binHeader))

        let accessors = json["accessors"] as! [[String: Any]]
        let views = json["bufferViews"] as! [[String: Any]]
        let materials = json["materials"] as! [[String: Any]]
        let meshes = json["meshes"] as! [[String: Any]]
        let nodes = json["nodes"] as! [[String: Any]]

        func floats(_ accessorIndex: Int, components: Int) -> [Float] {
            let a = accessors[accessorIndex]
            let view = views[a["bufferView"] as! Int]
            let count = a["count"] as! Int
            let base = (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            let stride = view["byteStride"] as? Int ?? components * 4
            var out = [Float](repeating: 0, count: count * components)
            bin.withUnsafeBytes { raw in
                for i in 0..<count {
                    for c in 0..<components {
                        out[i * components + c] = raw.loadUnaligned(fromByteOffset: base + i * stride + c * 4, as: Float.self)
                    }
                }
            }
            return out
        }
        func indices(_ accessorIndex: Int) -> [UInt32] {
            let a = accessors[accessorIndex]
            let view = views[a["bufferView"] as! Int]
            let count = a["count"] as! Int
            let base = (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            let type = a["componentType"] as! Int
            return bin.withUnsafeBytes { raw in
                (0..<count).map { i in
                    switch type {
                    case 5125: return raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                    case 5123: return UInt32(raw.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self))
                    default: return UInt32(raw.loadUnaligned(fromByteOffset: base + i, as: UInt8.self))
                    }
                }
            }
        }

        var result: [GLBMesh] = []
        for node in nodes {
            guard let meshIndex = node["mesh"] as? Int else { continue }
            let part = (node["extras"] as? [String: Any])?["assemblyPart"] as? String
            for primitive in meshes[meshIndex]["primitives"] as! [[String: Any]] {
                let attributes = primitive["attributes"] as! [String: Int]
                let p = floats(attributes["POSITION"]!, components: 3)
                let n = attributes["NORMAL"].map { floats($0, components: 3) } ?? []
                let t = attributes["TEXCOORD_0"].map { floats($0, components: 2) } ?? []
                let material = materials[primitive["material"] as! Int]
                let pbr = material["pbrMetallicRoughness"] as? [String: Any] ?? [:]
                let color = (pbr["baseColorFactor"] as? [Double]) ?? [1, 1, 1, 1]
                let name = (material["name"] as! String)
                    .replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
                result.append(GLBMesh(
                    materialName: name,
                    part: part,
                    positions: stride(from: 0, to: p.count, by: 3).map { SIMD3(p[$0], p[$0 + 1], p[$0 + 2]) },
                    normals: stride(from: 0, to: n.count, by: 3).map { SIMD3(n[$0], n[$0 + 1], n[$0 + 2]) },
                    uvs: stride(from: 0, to: t.count, by: 2).map { SIMD2(t[$0], t[$0 + 1]) },
                    indices: indices(primitive["indices"] as! Int),
                    baseColor: SIMD3(Float(color[0]), Float(color[1]), Float(color[2])),
                    metallic: Float(pbr["metallicFactor"] as? Double ?? 0),
                    roughness: Float(pbr["roughnessFactor"] as? Double ?? 0.5)
                ))
            }
        }
        return result
    }
}
