// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Sizeup2",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Geometry"),
        .target(name: "WindowKit", dependencies: ["Geometry"]),
        .target(name: "Hotkeys"),
        .executableTarget(name: "App", dependencies: ["Geometry", "WindowKit", "Hotkeys"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ],
    swiftLanguageModes: [.v6]
)
