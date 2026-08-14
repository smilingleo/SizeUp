// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Sizeup2",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.0.0")
    ],
    targets: [
        .target(name: "Geometry"),
        .target(name: "WindowKit", dependencies: ["Geometry"]),
        .target(name: "Hotkeys"),
        .executableTarget(name: "App", dependencies: ["Geometry", "WindowKit", "Hotkeys"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", .product(name: "Testing", package: "swift-testing")]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit", .product(name: "Testing", package: "swift-testing")]),
        .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys", .product(name: "Testing", package: "swift-testing")]),
    ],
    swiftLanguageModes: [.v6]
)
