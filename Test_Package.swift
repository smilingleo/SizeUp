// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Sizeup2",
    targets: [
        .target(name: "Geometry"),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry"]),
    ],
    swiftLanguageModes: [.v6]
)
