import Testing
import CoreGraphics
@testable import WindowKit

/// The development machine's real layout: a 3360x1890 built-in display and a
/// 2056x1329 external display mounted higher, which puts its Cocoa origin at
/// a negative Y. Negative origins are where sign errors surface.
private let primary = CGRect(x: 0, y: 0, width: 3360, height: 1890)

@Test func cocoaOriginMapsToAXTopLeft() {
    let cocoa = CGRect(x: 0, y: 0, width: 100, height: 100)
    let ax = axRect(fromCocoa: cocoa, primaryFrame: primary)
    // Bottom-left of the primary display is 1890 - 100 = 1790 from the top.
    #expect(ax == CGRect(x: 0, y: 1790, width: 100, height: 100))
}

@Test func topLeftWindowHasZeroAXY() {
    let cocoa = CGRect(x: 0, y: 1790, width: 100, height: 100)
    let ax = axRect(fromCocoa: cocoa, primaryFrame: primary)
    #expect(ax.origin.y == 0)
}

/// The external display sits at Cocoa y = -838 with height 1329, so its top
/// edge is at Cocoa y = 491, which is AX y = 1890 - 491 = 1399.
@Test func externalDisplayWithNegativeOriginConvertsCorrectly() {
    let cocoa = CGRect(x: 3360, y: -838, width: 2056, height: 1329)
    let ax = axRect(fromCocoa: cocoa, primaryFrame: primary)
    #expect(ax == CGRect(x: 3360, y: 1399, width: 2056, height: 1329))
}

@Test func conversionRoundTripsForAllRealisticRects() {
    let rects = [
        CGRect(x: 0, y: 0, width: 1680, height: 1860),
        CGRect(x: 3360, y: -838, width: 2056, height: 1329),
        CGRect(x: -1440, y: 300, width: 1440, height: 900),
        CGRect(x: 1680, y: 930, width: 1680, height: 930),
    ]
    for r in rects {
        let there = axRect(fromCocoa: r, primaryFrame: primary)
        let back = cocoaRect(fromAX: there, primaryFrame: primary)
        #expect(back == r)
    }
}

/// X is never transformed, and size is never transformed.
@Test func conversionPreservesXAndSize() {
    let cocoa = CGRect(x: 512, y: 77, width: 640, height: 480)
    let ax = axRect(fromCocoa: cocoa, primaryFrame: primary)
    #expect(ax.origin.x == 512)
    #expect(ax.size == cocoa.size)
}
