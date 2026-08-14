import CoreGraphics
import Geometry
import Testing
import WindowKit
@testable import Core

// Fixtures (builtIn, external, TestWindow, makeRouter) live in RouterFixtures.swift.

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

    #expect(store.retainedPlacement(for: window.key, currentFrame: window.stored)?.step == 0)
    #expect(store.retainedPlacement(for: window.key, currentFrame: window.stored)?.action == .half(.left))
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

    #expect(window.stored == original)
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
        screens: TestScreens(screens: [builtIn, external]),
        windows: TestWindows(window: window),
        store: store,
        skipList: ["com.example.locked"]
    )

    router.perform(.display(.next))

    #expect(window.applied.isEmpty)
    #expect(store.count == 0)
}

/// The step-preservation test that can actually fail.
///
/// With a single span every step index resolves to the same width, so the
/// earlier tests could not distinguish "preserved the step" from "advanced it"
/// or "reset it". With three spans the three outcomes are three different
/// widths on the destination display: preserved 1370, advanced 685, reset 1028.
@MainActor
@Test func displayMoveReAppliesTheRetainedSpanNotTheNextOne() {
    let spans: [Span] = [.half, Span(occupied: 2, of: 3), Span(occupied: 1, of: 3)]
    let store = WindowStateStore()
    let window = TestWindow(frame: CGRect(x: 300, y: 300, width: 800, height: 600))
    let router = makeRouter(
        window: window, screens: [builtIn, external], spans: spans, store: store
    )

    router.perform(.half(.left))
    #expect(window.stored.width == 1680)  // span 0: 1/2 of 3360

    router.perform(.half(.left))
    #expect(window.stored.width == 2240)  // span 1: 2/3 of 3360

    router.perform(.display(.next))
    #expect(window.stored == CGRect(x: 3360, y: -838, width: 1370, height: 1291))

    // And the cycle resumes from the right place on the new display: the press
    // after a move advances exactly one span rather than repeating or skipping.
    router.perform(.half(.left))
    #expect(window.stored.width == 685)  // span 2: 1/3 of 2056
}

/// A third display, left of the built-in one, so that `.next` and `.previous`
/// lead to DIFFERENT displays. With only two displays both directions wrap to
/// the same place, and a router that ignored the direction entirely would pass.
private let thirdDisplay = ScreenInfo(
    id: 3,
    frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)
)

@MainActor
@Test func previousDirectionIsPlumbedThroughRatherThanHardcoded() {
    let store = WindowStateStore()
    let leftHalf = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let window = TestWindow(frame: leftHalf)
    store.record(key: window.key, action: .half(.left), achievedFrame: leftHalf,
                 previousFrame: CGRect(x: 10, y: 10, width: 100, height: 100))
    let router = makeRouter(
        window: window, screens: [thirdDisplay, builtIn, external], store: store
    )

    router.perform(.display(.previous))

    // Left of the built-in display, not right of it.
    #expect(window.stored == CGRect(x: -1920, y: 0, width: 960, height: 1055))
}

@MainActor
@Test func nextAndPreviousAreOppositeWithThreeDisplays() {
    let store = WindowStateStore()
    let start = CGRect(x: 300, y: 300, width: 800, height: 600)
    let window = TestWindow(frame: start)
    let router = makeRouter(
        window: window, screens: [thirdDisplay, builtIn, external], store: store
    )

    router.perform(.display(.next))
    #expect(external.visibleFrame.contains(window.stored))

    router.perform(.display(.previous))
    #expect(builtIn.visibleFrame.contains(window.stored))
}

@MainActor
@Test func verticalDirectionsAreNotDisplayMoves() {
    // `.above`/`.below` are reserved for Spaces in M4. They must do nothing
    // here, not fall back to next/previous.
    let store = WindowStateStore()
    let start = CGRect(x: 300, y: 300, width: 800, height: 600)
    let window = TestWindow(frame: start)
    let router = makeRouter(window: window, screens: [builtIn, external], store: store)

    router.perform(.display(.above))
    router.perform(.display(.below))

    #expect(window.applied.isEmpty)
    #expect(window.stored == start)
}

@MainActor
@Test func retiledWindowThatResistsResizingStillTracksWhatItAchieved() {
    // An app with a minimum size moved onto a smaller display cannot honour the
    // request. The store must record what was ACHIEVED, or the next press would
    // not recognise the window as one of ours.
    let store = WindowStateStore()
    let leftHalf = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let window = TestWindow(frame: leftHalf, minSize: CGSize(width: 1500, height: 0))
    store.record(key: window.key, action: .half(.left), achievedFrame: leftHalf,
                 previousFrame: CGRect(x: 10, y: 10, width: 100, height: 100))
    let router = makeRouter(
        window: window, screens: [builtIn, external], store: store
    )

    router.perform(.display(.next))

    // Requested 1028 wide, but the app refuses to go below 1500.
    #expect(window.applied.last?.width == 1028)
    #expect(window.stored.width == 1500)
    #expect(store.retainedPlacement(for: window.key, currentFrame: window.stored)?.action == .half(.left))
}

@MainActor
@Test func aWindowReportingAGarbageFrameIsLeftAlone() {
    // A hung app can report a NaN frame through the Accessibility API. Such a
    // frame must not be written back: a window at a non-finite position has
    // nothing left on screen to drag. Nothing should be recorded either, or the
    // store would claim a layout the window does not have.
    let store = WindowStateStore()
    let window = TestWindow(frame: CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600))
    let router = makeRouter(window: window, screens: [builtIn, external], store: store)

    router.perform(.display(.next))

    #expect(window.applied.isEmpty)
    #expect(store.count == 0)
}

@MainActor
@Test func theProportionalFallbackRecordsTheDirectionActuallyPressed() {
    let store = WindowStateStore()
    let window = TestWindow(frame: CGRect(x: 300, y: 300, width: 800, height: 600))
    let router = makeRouter(
        window: window, screens: [thirdDisplay, builtIn, external], store: store
    )

    router.perform(.display(.previous))

    #expect(store.retainedPlacement(for: window.key, currentFrame: window.stored)?.action
        == .display(.previous))
}
