// swift-tools-version: 6.3
import PackageDescription

// swift-testing is a test-only dependency and never links into the shipped app.
//
// The toolchain now bundles Swift Testing and emits a deprecation warning at every
// `@Test` telling us to drop this dependency. Dropping it was tried and does not
// work on this machine: without Xcode installed, `import Testing` then fails with
// "missing required module '_TestingInternals'". So the warning is currently
// unactionable and the dependency stays. Revisit when Xcode is present, or when
// the toolchain ships the internals module — this is also the CI hazard recorded
// in the deferred findings, since a runner WITH Xcode will conflict on it.
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
        .executableTarget(name: "App", dependencies: ["Geometry", "WindowKit", "Hotkeys", "Core", "Config"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", testing]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit", "Geometry", testing]),
        .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys", testing]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "Geometry", "WindowKit", "Hotkeys", testing]),
        .testTarget(name: "ConfigTests", dependencies: ["Config", "Geometry", testing]),
    ],
    swiftLanguageModes: [.v6]
)
