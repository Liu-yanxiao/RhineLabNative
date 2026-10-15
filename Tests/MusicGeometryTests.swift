import XCTest
@testable import RhineLab

final class MusicGeometryTests: XCTestCase {
    func testRealModelInsertsDoNotShareRimDepthPlanes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let meshes = try GLB.parse(Data(contentsOf: root.appendingPathComponent("Resources/Models/music-cd.glb"))).map(MusicGeometry.fitted)
        let rim = try XCTUnwrap(meshes.first { $0.materialName == "Ivory_Edges" })
        let upper = try XCTUnwrap(rim.positions.map(\.y).max())
        let lower = try XCTUnwrap(rim.positions.map(\.y).min())
        for name in ["Frosted_Polymer", "Optical_Diffuser"] {
            let insert = try XCTUnwrap(meshes.first { $0.materialName == name })
            XCTAssertGreaterThan(upper - (insert.positions.map(\.y).max() ?? upper), 0.015, name)
            XCTAssertGreaterThan((insert.positions.map(\.y).min() ?? lower) - lower, 0.015, name)
        }
    }
}
