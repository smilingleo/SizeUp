// swift-tools-version: 6.3
import PackageDescription

// swift-testing is a test-only dependency. This machine has Command Line
// Tools but no Xcode, so neither the toolchain-bundled Testing module nor
// XCTest is importable; the package supplies Testing. It never links into
// the shipped app.
let testing = Target.Dependency.product(name: "Testing", package: "swift-testing")

let package = Package(
    name: "Sizeup2",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.99.0")
    ],
    targets: [
        .target(name: "Geometry"),
        .target(name: "WindowKit", dependencies: ["Geometry"]),
        .target(name: "Hotkeys"),
        .target(name: "Core", dependencies: ["Geometry", "WindowKit", "Hotkeys"]),
        .target(name: "Config", dependencies: ["Geometry"]),
        .executableTarget(name: "App", dependencies: ["Geometry", "WindowKit", "Hotkeys", "Core"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", testing]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit", "Geometry", testing]),
        .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys", testing]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "Geometry", "WindowKit", "Hotkeys", testing]),
        .testTarget(name: "ConfigTests", dependencies: ["Config", "Geometry", testing]),
    ],
    swiftLanguageModes: [.v6]
)
