import Testing
import CoreGraphics
@testable import Geometry

private let builtIn = ScreenInfo(
    id: 0,
    frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)

@Test func fullScreenFillsVisibleFrame() {
    #expect(targetFrame(for: .fullScreen, on: builtIn) == builtIn.visibleFrame)
}

@Test func fullScreenRespectsOuterMargin() {
    let r = targetFrame(for: .fullScreen, on: builtIn, gaps: Gaps(outer: 12))!
    #expect(r == CGRect(x: 12, y: 12, width: 3336, height: 1836))
}

/// Upper-left means high Y, low X in Cocoa coordinates.
@Test func upperLeftQuarterIsTopLeft() {
    let r = targetFrame(for: .quarter(.upperLeft), on: builtIn)!
    #expect(r == CGRect(x: 0, y: 930, width: 1680, height: 930))
}

@Test func lowerRightQuarterIsBottomRight() {
    let r = targetFrame(for: .quarter(.lowerRight), on: builtIn)!
    #expect(r == CGRect(x: 1680, y: 0, width: 1680, height: 930))
}

/// The four quarters must exactly cover the visible frame with no
/// overlaps and no uncovered pixels.
@Test func fourQuartersTileTheScreenExactly() {
    let odd = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 1401, height: 901),
        visibleFrame: CGRect(x: 0, y: 0, width: 1401, height: 901)
    )
    let rects = Corner.allCases.map { targetFrame(for: .quarter($0), on: odd)! }
    let area = rects.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
    #expect(area == CGFloat(1401 * 901))
    for (i, a) in rects.enumerated() {
        for b in rects[(i + 1)...] {
            #expect(a.intersection(b).isEmpty)
        }
    }
}

/// Center preserves the window's size — matching SizeUp, whose Center
/// preference entry carries no Width/Height.
@Test func centerPreservesWindowSize() {
    let current = CGRect(x: 10, y: 10, width: 800, height: 600)
    let r = targetFrame(for: .center, on: builtIn, current: current)!
    #expect(r.size == current.size)
    #expect(r == CGRect(x: 1280, y: 630, width: 800, height: 600))
}

/// A window larger than the screen is clamped rather than centered
/// with negative origins that would push it off-screen.
@Test func centerClampsOversizedWindow() {
    let huge = CGRect(x: 0, y: 0, width: 5000, height: 3000)
    let r = targetFrame(for: .center, on: builtIn, current: huge)!
    #expect(r == builtIn.visibleFrame)
}

@Test func centerWithoutCurrentFrameReturnsNil() {
    #expect(targetFrame(for: .center, on: builtIn) == nil)
}

/// These are dispatched by the router, not by frame math.
@Test func nonGeometricActionsReturnNil() {
    #expect(targetFrame(for: .snapBack, on: builtIn) == nil)
    #expect(targetFrame(for: .display(.next), on: builtIn) == nil)
    #expect(targetFrame(for: .space(.next), on: builtIn) == nil)
}

@Test func onlyHalvesCycle() {
    #expect(Action.half(.left).cycles)
    #expect(!Action.quarter(.upperLeft).cycles)
    #expect(!Action.center.cycles)
    #expect(!Action.fullScreen.cycles)
}
