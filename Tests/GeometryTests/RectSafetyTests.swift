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
