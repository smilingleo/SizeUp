import Testing
import CoreGraphics
import Geometry
import WindowKit
@testable import Core

private let builtIn = ScreenInfo(
    id: 0,
    frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)

/// The real external display: mounted higher, so its Cocoa origin Y is negative.
private let external = ScreenInfo(
    id: 1,
    frame: CGRect(x: 3360, y: -838, width: 2056, height: 1329),
    visibleFrame: CGRect(x: 3360, y: -838, width: 2056, height: 1291)
)

private final class TestWindow: WindowHandle {
    let key: WindowKey
    var bundleIdentifier: String?
    var stored: CGRect
    var minSize: CGSize
    private(set) var applied: [CGRect] = []

    init(key: WindowKey = WindowKey(pid: 1, elementHash: 1),
         frame: CGRect,
         bundleIdentifier: String? = "com.example.app",
         minSize: CGSize = .zero) {
        self.key = key
        self.stored = frame
        self.bundleIdentifier = bundleIdentifier
        self.minSize = minSize
    }

    func frame() -> CGRect? { stored }

    @discardableResult
    func setFrame(_ cocoaRect: CGRect) -> CGRect? {
        applied.append(cocoaRect)
        stored = CGRect(
            origin: cocoaRect.origin,
            size: CGSize(width: max(cocoaRect.width, minSize.width),
                         height: max(cocoaRect.height, minSize.height))
        )
        return stored
    }
}

private struct TestScreens: ScreenProviding {
    var screens: [ScreenInfo]
    var primaryFrame: CGRect { screens[0].frame }
}

private struct TestWindows: WindowProviding {
    var window: WindowHandle?
    /// Counts lookups so tests can prove the router queried but did not act.
    final class Counter { var lookups = 0 }
    let counter = Counter()
    func focusedWindow() -> WindowHandle? {
        counter.lookups += 1
        return window
    }
}

@MainActor
private func makeRouter(
    window: WindowHandle?,
    screens: [ScreenInfo] = [builtIn],
    spans: [Span] = [.half],
    skipList: Set<String> = [],
    store: WindowStateStore = WindowStateStore()
) -> ActionRouter {
    ActionRouter(
        screens: TestScreens(screens: screens),
        windows: TestWindows(window: window),
        store: store,
        gaps: .zero,
        spans: spans,
        skipList: skipList
    )
}

@MainActor
@Test func placesWindowInLeftHalf() {
    let w = TestWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
    makeRouter(window: w).perform(.half(.left))
    #expect(w.stored == CGRect(x: 0, y: 0, width: 1680, height: 1860))
}

/// The display is chosen by largest overlap, not by window origin.
@Test @MainActor func choosesDisplayWithLargestOverlap() {
    // Mostly on the external display, but its origin lies on the built-in.
    let w = TestWindow(frame: CGRect(x: 3300, y: 0, width: 1000, height: 600))
    makeRouter(window: w, screens: [builtIn, external]).perform(.fullScreen)
    #expect(w.stored == external.visibleFrame)
}

@MainActor
@Test func windowFullyOnBuiltInStaysThere() {
    let w = TestWindow(frame: CGRect(x: 10, y: 10, width: 400, height: 300))
    makeRouter(window: w, screens: [builtIn, external]).perform(.fullScreen)
    #expect(w.stored == builtIn.visibleFrame)
}

/// A window entirely off every display still has to go somewhere sensible.
@MainActor
@Test func windowWithNoOverlapFallsBackToPrimary() {
    let w = TestWindow(frame: CGRect(x: -9000, y: -9000, width: 200, height: 200))
    makeRouter(window: w, screens: [builtIn, external]).perform(.fullScreen)
    #expect(w.stored == builtIn.visibleFrame)
}

@MainActor
@Test func centerKeepsSizeAndUsesCurrentFrame() {
    let w = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    makeRouter(window: w).perform(.center)
    #expect(w.stored == CGRect(x: 1280, y: 630, width: 800, height: 600))
}

@MainActor
@Test func snapBackRestoresFrameFromBeforeFirstAction() {
    let original = CGRect(x: 250, y: 175, width: 900, height: 700)
    let w = TestWindow(frame: original)
    let router = makeRouter(window: w)
    router.perform(.half(.left))
    #expect(w.stored != original)
    router.perform(.snapBack)
    #expect(w.stored == original)
}

@MainActor
@Test func snapBackDoesNothingForUnmanagedWindow() {
    let original = CGRect(x: 250, y: 175, width: 900, height: 700)
    let w = TestWindow(frame: original)
    makeRouter(window: w).perform(.snapBack)
    #expect(w.stored == original)
    #expect(w.applied.isEmpty)
}

/// A stored frame lands on a display that has since disconnected: Snap Back
/// must not send the window somewhere unreachable.
@MainActor
@Test func snapBackClampsToCurrentScreenWhenStoredDisplayIsGone() {
    let disconnectedDisplayFrame = CGRect(x: 3360, y: -838, width: 900, height: 700)
    let w = TestWindow(frame: disconnectedDisplayFrame)
    let store = WindowStateStore()
    // Pretend the window was tiled while the external display existed, then
    // it got unplugged: only `builtIn` remains among current screens.
    store.record(key: w.key, action: .half(.left),
                 achievedFrame: CGRect(x: 0, y: 0, width: 400, height: 400),
                 previousFrame: disconnectedDisplayFrame)
    w.stored = CGRect(x: 0, y: 0, width: 400, height: 400)
    let router = makeRouter(window: w, screens: [builtIn], store: store)
    router.perform(.snapBack)
    #expect(builtIn.visibleFrame.intersects(w.stored))
    #expect(w.stored != disconnectedDisplayFrame)
}

/// With a single span, repeated presses are idempotent — M1 behavior.
@MainActor
@Test func repeatedPressIsIdempotentWithOneSpan() {
    let w = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let router = makeRouter(window: w, spans: [.half])
    router.perform(.half(.left))
    let afterFirst = w.stored
    router.perform(.half(.left))
    #expect(w.stored == afterFirst)
}

/// With three spans, repeated presses advance and then wrap — M3 behavior,
/// verified now because the wrapping logic ships in this task.
@MainActor
@Test func repeatedPressCyclesThroughSpansAndWraps() {
    let w = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let router = makeRouter(
        window: w,
        spans: [.half, Span(occupied: 2, of: 3), Span(occupied: 1, of: 3)]
    )
    router.perform(.half(.left))
    #expect(w.stored.width == 1680)
    router.perform(.half(.left))
    #expect(w.stored.width == 2240)
    router.perform(.half(.left))
    #expect(w.stored.width == 1120)
    router.perform(.half(.left))
    #expect(w.stored.width == 1680)
}

/// Applications on the skip list are never touched.
@MainActor
@Test func skipListPreventsPlacement() {
    let w = TestWindow(frame: CGRect(x: 5, y: 5, width: 300, height: 200),
                       bundleIdentifier: "com.apple.QuickTimePlayerX")
    let store = WindowStateStore()
    let router = makeRouter(window: w, skipList: ["com.apple.QuickTimePlayerX"], store: store)
    router.perform(.half(.left))
    #expect(w.applied.isEmpty)
    #expect(w.stored == CGRect(x: 5, y: 5, width: 300, height: 200))
    #expect(store.count == 0)
}

@MainActor
@Test func noFocusedWindowIsQueriedButNothingIsApplied() {
    let windows = TestWindows(window: nil)
    let store = WindowStateStore()
    let router = ActionRouter(
        screens: TestScreens(screens: [builtIn]),
        windows: windows,
        store: store,
        gaps: .zero,
        spans: [.half],
        skipList: []
    )
    router.perform(.half(.left))
    #expect(windows.counter.lookups == 1)
    #expect(store.count == 0)
}

/// Windows that clamp to a minimum size must still cycle: the store has to
/// remember the achieved frame, not the requested one.
@MainActor
@Test func clampedWindowStillCyclesOnRepeat() {
    let w = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                       minSize: CGSize(width: 2000, height: 100))
    let router = makeRouter(window: w, spans: [.half, Span(occupied: 1, of: 3)])
    router.perform(.half(.left))
    #expect(w.stored.width == 2000)  // clamped up from 1680
    router.perform(.half(.left))
    #expect(w.applied.count == 2)
    #expect(w.applied[1].width == 1120)  // advanced to the third
}
