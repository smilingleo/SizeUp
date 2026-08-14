import CoreGraphics
import Testing
@testable import Geometry

@Test func nonFiniteRectsAreRejected() {
    #expect(CGRect(x: 0, y: 0, width: 100, height: 100).isSafeToApply)
    #expect(CGRect(x: -838, y: -100, width: 1, height: 1).isSafeToApply)  // negative origin is legitimate

    #expect(!CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100).isSafeToApply)
    #expect(!CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100).isSafeToApply)
    #expect(!CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100).isSafeToApply)
    #expect(!CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan).isSafeToApply)
    #expect(!CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100).isSafeToApply)
    #expect(!CGRect(x: 0, y: 0, width: -100, height: 100).isSafeToApply)
    #expect(!CGRect(x: 0, y: 0, width: 100, height: -100).isSafeToApply)
}

@Test func aZeroSizeRectIsRefused() {
    // As unrecoverable as a non-finite one: there is nothing on screen to grab.
    #expect(!CGRect(x: 10, y: 10, width: 0, height: 100).isSafeToApply)
    #expect(!CGRect(x: 10, y: 10, width: 100, height: 0).isSafeToApply)
}

@Test func aGapWideEnoughToConsumeTheAxisYieldsNoPlacement() {
    // Measured, not theoretical: inner 100 is a value the Settings window
    // offers, and 12 columns is what the settings validator accepts. Together
    // they used to produce a zero-height window on an ordinary 1080p display,
    // which isSafeToApply then permitted.
    let hd = ScreenInfo(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
    )
    let twelfth = Span(occupied: 1, of: 12)
    let wide = Gaps(inner: 100, outer: 0)

    #expect(targetFrame(for: .half(.bottom), on: hd, gaps: wide, span: twelfth) == nil)
    // The same configuration across the wider axis still fits, and must not be
    // refused just because the other axis did not.
    #expect(targetFrame(for: .half(.left), on: hd, gaps: wide, span: twelfth) != nil)
}
