import simd

/// The source model has coplanar top/bottom faces on its frame and two inserts.
/// Recess the inserts inside the rim so animated depth tests never alternate materials.
enum MusicGeometry {
    static func fitted(_ mesh: GLBMesh) -> GLBMesh {
        let insert = mesh.materialName == "Frosted_Polymer" || mesh.materialName == "Optical_Diffuser"
        let scale = SIMD3<Float>(4.45 / 4.3, (insert ? 3.31 : 3.35) / 3.7, 0.14 / 0.26)
        let center = SIMD3<Float>(0, 1.85, 0)
        return GLBMesh(materialName: mesh.materialName, part: mesh.part,
                       positions: mesh.positions.map { ($0 - center) * scale + center },
                       normals: mesh.normals.map { simd_normalize($0 / scale) },
                       uvs: mesh.uvs, indices: mesh.indices, baseColor: mesh.baseColor,
                       metallic: mesh.metallic, roughness: mesh.roughness)
    }
}
