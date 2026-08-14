import Testing
import CoreGraphics
import Geometry
import WindowKit
@testable import Core

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

/// A stored frame with only a sliver of overlap on the current screen —
/// exactly what a resolution change can produce — must still be treated as
/// unreachable and clamped, not applied verbatim.
@MainActor
@Test func snapBackClampsWhenOnlyASliverOverlapsTheCurrentScreen() {
    // Mostly off the left edge of `builtIn`: only 20pt of width overlaps.
    let sliverOverlap = CGRect(x: -880, y: 0, width: 900, height: 700)
    let w = TestWindow(frame: sliverOverlap)
    let store = WindowStateStore()
    let placed = CGRect(x: 0, y: 0, width: 400, height: 400)
    store.record(key: w.key, action: .half(.left), achievedFrame: placed, previousFrame: sliverOverlap)
    w.stored = placed
    let router = makeRouter(window: w, screens: [builtIn], store: store)
    router.perform(.snapBack)
    #expect(w.stored != sliverOverlap)
    #expect(builtIn.visibleFrame.contains(CGPoint(x: w.stored.midX, y: w.stored.midY)))
}

/// The centering fallback must not place a window one point off the edge
/// of `visibleFrame` when its size fills the whole screen — `.rounded(.down)`
/// on the midpoint can otherwise push the origin below `visible.minX`/`minY`.
@MainActor
@Test func snapBackClampCentersFullSizeWindowWithoutOverhang() {
    let sliverOverlap = CGRect(x: -3000, y: 0, width: builtIn.visibleFrame.width, height: builtIn.visibleFrame.height)
    let w = TestWindow(frame: sliverOverlap)
    let store = WindowStateStore()
    let placed = CGRect(x: 0, y: 0, width: 400, height: 400)
    store.record(key: w.key, action: .half(.left), achievedFrame: placed, previousFrame: sliverOverlap)
    w.stored = placed
    let router = makeRouter(window: w, screens: [builtIn], store: store)
    router.perform(.snapBack)
    #expect(w.stored.minX >= builtIn.visibleFrame.minX)
    #expect(w.stored.minY >= builtIn.visibleFrame.minY)
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
