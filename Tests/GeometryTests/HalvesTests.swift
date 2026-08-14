import Testing
import CoreGraphics
@testable import Geometry

/// The user's built-in display: 3360x1890 with a 30pt menu bar.
private let builtIn = ScreenInfo(
    id: 0,
    frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)

@Test func leftHalfFillsLeftOfVisibleFrame() {
    let r = targetFrame(for: .half(.left), on: builtIn)
    #expect(r == CGRect(x: 0, y: 0, width: 1680, height: 1860))
}

@Test func rightHalfFillsRightOfVisibleFrame() {
    let r = targetFrame(for: .half(.right), on: builtIn)
    #expect(r == CGRect(x: 1680, y: 0, width: 1680, height: 1860))
}

/// Top half must sit at high Y in Cocoa coordinates, and must not
/// overlap the menu bar — which visibleFrame already excludes.
@Test func topHalfUsesHighYAndAvoidsMenuBar() {
    let r = targetFrame(for: .half(.top), on: builtIn)
    #expect(r == CGRect(x: 0, y: 930, width: 3360, height: 930))
    #expect(r!.maxY <= builtIn.visibleFrame.maxY)
}

@Test func bottomHalfUsesLowY() {
    let r = targetFrame(for: .half(.bottom), on: builtIn)
    #expect(r == CGRect(x: 0, y: 0, width: 3360, height: 930))
}

/// A Dock on the left insets visibleFrame's origin. Placement must
/// follow it, not assume the screen starts at frame.origin.
@Test func leftHalfRespectsDockOnLeft() {
    let dockLeft = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
        visibleFrame: CGRect(x: 80, y: 0, width: 3280, height: 1860)
    )
    let r = targetFrame(for: .half(.left), on: dockLeft)
    #expect(r == CGRect(x: 80, y: 0, width: 1640, height: 1860))
}

/// On an odd width the two halves must tile exactly: no 1pt seam,
/// no 1pt overlap. Leading edge floors, trailing edge takes the remainder.
@Test func oddWidthHalvesTileExactly() {
    let odd = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 1401, height: 901),
        visibleFrame: CGRect(x: 0, y: 0, width: 1401, height: 901)
    )
    let left = targetFrame(for: .half(.left), on: odd)!
    let right = targetFrame(for: .half(.right), on: odd)!
    #expect(left.width == 700)
    #expect(right.width == 701)
    #expect(left.maxX == right.minX)
    #expect(left.width + right.width == 1401)
}

@Test func oddHeightHalvesTileExactly() {
    let odd = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 1401, height: 901),
        visibleFrame: CGRect(x: 0, y: 0, width: 1401, height: 901)
    )
    let bottom = targetFrame(for: .half(.bottom), on: odd)!
    let top = targetFrame(for: .half(.top), on: odd)!
    #expect(bottom.height == 450)
    #expect(top.height == 451)
    #expect(bottom.maxY == top.minY)
}

/// Outer margin insets all four sides; inner gap splits the shared edge
/// so two adjacent halves end up exactly `inner` apart.
@Test func gapsInsetEdgesAndSplitSharedBoundary() {
    let g = Gaps(inner: 10, outer: 20)
    let left = targetFrame(for: .half(.left), on: builtIn, gaps: g)!
    let right = targetFrame(for: .half(.right), on: builtIn, gaps: g)!
    #expect(left.minX == 20)
    #expect(right.maxX == 3340)
    #expect(left.minY == 20)
    #expect(left.height == 1820)
    #expect(right.minX - left.maxX == 10)
}

/// A two-thirds and a one-third window must tile the screen exactly,
/// with and without an inner gap. Spans are M3 behavior, but the
/// arithmetic ships now.
@Test func twoThirdsAndOneThirdTileExactly() {
    let big = targetFrame(for: .half(.left), on: builtIn, span: Span(occupied: 2, of: 3))!
    let small = targetFrame(for: .half(.right), on: builtIn, span: Span(occupied: 1, of: 3))!
    #expect(big.maxX == small.minX)
    #expect(big.width + small.width == 3360)
}

/// The case a bare-fraction implementation gets wrong: with a nonzero inner
/// gap, an asymmetric split must still tile the axis exactly. Both sides have
/// to agree that a 3-column layout has 2 inner gaps.
@Test func asymmetricSplitWithInnerGapTilesExactly() {
    let g = Gaps(inner: 10)
    let big = targetFrame(for: .half(.left), on: builtIn, gaps: g, span: Span(occupied: 2, of: 3))!
    let small = targetFrame(for: .half(.right), on: builtIn, gaps: g, span: Span(occupied: 1, of: 3))!
    #expect(big.width == 2236)
    #expect(small.width == 1114)
    #expect(small.minX - big.maxX == 10)
    #expect(big.width + small.width + 10 == 3360)

    // And with the spans swapped.
    let small2 = targetFrame(for: .half(.left), on: builtIn, gaps: g, span: Span(occupied: 1, of: 3))!
    let big2 = targetFrame(for: .half(.right), on: builtIn, gaps: g, span: Span(occupied: 2, of: 3))!
    #expect(small2.width == 1113)
    #expect(big2.width == 2237)
    #expect(big2.minX - small2.maxX == 10)
}
