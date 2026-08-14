import CoreGraphics
import Geometry
import Testing
import WindowKit
@testable import Core

private let builtIn = ScreenInfo(
    id: 1, frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)
private let external = ScreenInfo(
    id: 2, frame: CGRect(x: 3360, y: -838, width: 2056, height: 1329),
    visibleFrame: CGRect(x: 3360, y: -838, width: 2056, height: 1291)
)

private final class TestWindow: WindowHandle {
    var current: CGRect
    var applied: [CGRect] = []
    let key: WindowKey
    let bundleIdentifier: String?

    init(frame: CGRect, key: WindowKey = WindowKey(pid: 700, elementHash: 7), bundleIdentifier: String? = nil) {
        self.current = frame
        self.key = key
        self.bundleIdentifier = bundleIdentifier
    }

    func frame() -> CGRect? { current }

    func setFrame(_ rect: CGRect) -> CGRect? {
        applied.append(rect)
        current = rect
        return rect
    }
}

private struct TestWindows: WindowProviding {
    let window: TestWindow?
    func focusedWindow() -> WindowHandle? { window }
}

private struct TestScreens: ScreenProviding {
    let list: [ScreenInfo]
    var screens: [ScreenInfo] { list }
    var primaryFrame: CGRect { list.first?.frame ?? .zero }
}

@MainActor
private func makeRouter(
    window: TestWindow?,
    screens: [ScreenInfo],
    store: WindowStateStore
) -> ActionRouter {
    ActionRouter(
        screens: TestScreens(list: screens),
        windows: TestWindows(window: window),
        store: store
    )
}

@MainActor
@Test func tiledWindowIsRetiledExactlyOnTheDestinationDisplay() {
    // A left half of the built-in display becomes a left half of the external
    // display — recomputed, so it tiles exactly rather than being scaled.
    let store = WindowStateStore()
    let leftHalf = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let window = TestWindow(frame: leftHalf)
    store.record(key: window.key, action: .half(.left), achievedFrame: leftHalf,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))

    let router = makeRouter(window: window, screens: [builtIn, external], store: store)
    router.perform(.display(.next))

    #expect(window.applied == [CGRect(x: 3360, y: -838, width: 1028, height: 1291)])
}

@MainActor
@Test func retiledQuarterFillsTheDestinationEdgeExactly() throws {
    // Proportional scaling would give a height of 645 here and leave a
    // one-point gap at the top. Recomputing the quarter gives 646.
    let store = WindowStateStore()
    let upperRight = CGRect(x: 1680, y: 930, width: 1680, height: 930)
    let window = TestWindow(frame: upperRight)
    store.record(key: window.key, action: .quarter(.upperRight), achievedFrame: upperRight,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))

    let router = makeRouter(window: window, screens: [builtIn, external], store: store)
    router.perform(.display(.next))

    let moved = try #require(window.applied.first)
    #expect(moved == CGRect(x: 4388, y: -193, width: 1028, height: 646))
    #expect(moved.maxY == external.visibleFrame.maxY)
}

@MainActor
@Test func untrackedWindowIsMappedProportionally() {
    // No placement on record, so there is nothing to recompute.
    let store = WindowStateStore()
    let window = TestWindow(frame: CGRect(x: 1280, y: 630, width: 800, height: 600))
    let router = makeRouter(window: window, screens: [builtIn, external], store: store)

    router.perform(.display(.next))

    #expect(window.applied == [CGRect(x: 4143, y: -401, width: 489, height: 416)])
}

@MainActor
@Test func manuallyMovedWindowFallsBackToProportionalMapping() {
    // We tiled it, then the user dragged it. The record no longer describes
    // reality, so it must not be trusted.
    let store = WindowStateStore()
    let leftHalf = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let window = TestWindow(frame: CGRect(x: 1280, y: 630, width: 800, height: 600))
    store.record(key: window.key, action: .half(.left), achievedFrame: leftHalf,
                 previousFrame: CGRect(x: 10, y: 10, width: 100, height: 100))

    let router = makeRouter(window: window, screens: [builtIn, external], store: store)
    router.perform(.display(.next))

    #expect(window.applied == [CGRect(x: 4143, y: -401, width: 489, height: 416)])
}

@MainActor
@Test func displayMoveDoesNotAdvanceTheSizeCycle() {
    let store = WindowStateStore()
    let leftHalf = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let window = TestWindow(frame: leftHalf)
    store.record(key: window.key, action: .half(.left), achievedFrame: leftHalf,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))

    let router = makeRouter(window: window, screens: [builtIn, external], store: store)
    router.perform(.display(.next))

    #expect(store.retainedPlacement(for: window.key, currentFrame: window.current)?.step == 0)
    #expect(store.retainedPlacement(for: window.key, currentFrame: window.current)?.action == .half(.left))
}

@MainActor
@Test func snapBackAfterADisplayMoveReturnsToTheOriginalFrame() {
    let store = WindowStateStore()
    let original = CGRect(x: 100, y: 100, width: 800, height: 600)
    let window = TestWindow(frame: original)
    let router = makeRouter(window: window, screens: [builtIn, external], store: store)

    router.perform(.half(.left))
    router.perform(.display(.next))
    router.perform(.snapBack)

    #expect(window.current == original)
}

@MainActor
@Test func displayMoveIsANoOpWithASingleDisplay() {
    let store = WindowStateStore()
    let window = TestWindow(frame: CGRect(x: 1280, y: 630, width: 800, height: 600))
    let router = makeRouter(window: window, screens: [builtIn], store: store)

    router.perform(.display(.next))

    #expect(window.applied.isEmpty)
    #expect(store.count == 0)
}

@MainActor
@Test func skipListedApplicationIsNotMovedBetweenDisplays() {
    let store = WindowStateStore()
    let window = TestWindow(
        frame: CGRect(x: 1280, y: 630, width: 800, height: 600),
        bundleIdentifier: "com.example.locked"
    )
    let router = ActionRouter(
        screens: TestScreens(list: [builtIn, external]),
        windows: TestWindows(window: window),
        store: store,
        skipList: ["com.example.locked"]
    )

    router.perform(.display(.next))

    #expect(window.applied.isEmpty)
    #expect(store.count == 0)
}
