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
    name: "ClipShot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.99.0")
    ],
    targets: [
        .target(name: "Geometry"),
        // A dependency-free leaf so every layer can log. See `Log`'s doc for why
        // this is a target rather than a helper inside one.
        .target(name: "Diagnostics"),
        .target(name: "WindowKit", dependencies: ["Geometry", "Diagnostics"]),
        .target(name: "Hotkeys", dependencies: ["Diagnostics"]),
        .target(name: "Core", dependencies: ["Geometry", "WindowKit", "Hotkeys"]),
        .target(name: "Config", dependencies: ["Geometry", "Diagnostics"]),
        // The capture side of the merge. `Capture` and `Annotation` are AppKit-free
        // (CoreGraphics/ScreenCaptureKit/CoreText) so their logic is testable without
        // windows on screen; `OverlayUI` is the first AppKit layer over them.
        .target(name: "Capture"),
        .target(name: "Annotation"),
        // The recording editor: timed annotations over a decoded video. The first
        // target that legitimately needs both the renderer and the codec, which
        // is why `Compositor` had to live in `App` and video export does not.
        .target(name: "VideoEdit", dependencies: ["Annotation", "Capture"]),
        .target(name: "OverlayUI", dependencies: ["Capture", "Annotation", "VideoEdit"]),
        .executableTarget(name: "App", dependencies: ["Geometry", "Diagnostics", "WindowKit", "Hotkeys", "Core", "Config", "Capture", "Annotation", "VideoEdit", "OverlayUI"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", testing]),
        .testTarget(name: "WindowKitTests", dependencies: ["WindowKit", "Geometry", testing]),
        .testTarget(name: "HotkeysTests", dependencies: ["Hotkeys", testing]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", testing]),
        .testTarget(name: "AnnotationTests", dependencies: ["Annotation", testing]),
        .testTarget(name: "VideoEditTests", dependencies: ["VideoEdit", "Annotation", "Capture", testing]),
        .testTarget(name: "OverlayUITests", dependencies: ["OverlayUI", "Capture", "Annotation", "VideoEdit", testing]),
        // Config is a test-only dependency here: the SizeUp-import round-trip test
        // (Task 6, M4) needs both KeymapResolver (Core) and SizeUpImporter (Config)
        // in the same target, since the plist that seeded DefaultKeymap's literals
        // can only be checked against them by actually importing it. Core itself
        // still does not depend on Config — this edge is the test target's alone.
        .testTarget(name: "CoreTests", dependencies: ["Core", "Geometry", "WindowKit", "Hotkeys", "Config", testing]),
        .testTarget(name: "ConfigTests", dependencies: ["Config", "Geometry", testing]),
        // The executable is testable so `CaptureSessionTests` (Task 5) can drive the
        // state machine with fakes; the AppKit shell itself is covered by the manual
        // checklist. It depends on the whole feature surface because a capture flow
        // touches capture, annotation, and the overlay at once.
        .testTarget(name: "AppTests", dependencies: ["App", "Core", "Geometry", "Capture", "Annotation", "VideoEdit", "OverlayUI", testing]),
    ],
    swiftLanguageModes: [.v6]
)
