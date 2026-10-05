// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RhineLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RhineLab",
            path: "Sources/RhineLab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
