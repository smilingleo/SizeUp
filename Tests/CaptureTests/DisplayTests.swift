import Testing
import CoreGraphics
@testable import Capture

/// The production `CGDisplayLookup` is a thin wrapper over
/// `CGGetDisplaysWithPoint`, which cannot be pointed at a display that does
/// not exist — so the *matching and conversion logic* (`Display.resolve` and
/// `Display.display(forAppkitFrame:)`) is tested against this synthetic table,
/// and the real-mouse reader is covered by the manual checklist.
struct SyntheticDisplays: DisplayLookup {
    var displays: [DisplayLocation]
    var main: DisplayLocation

    var mainDisplay: DisplayLocation { main }

    func display(containing point: CGPoint) -> DisplayLocation? {
        displays.first { $0.bounds.contains(point) }
    }
}

// A two-display layout with the secondary positioned up-and-to-the-left of
// the primary: negative origins are where the top-left/bottom-left sign
// errors live, so every conversion test includes one.
private let primary = DisplayLocation(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 700))
private let secondary = DisplayLocation(id: 2, bounds: CGRect(x: -1400, y: -400, width: 1400, height: 900))

private func twoDisplayLookup() -> SyntheticDisplays {
    SyntheticDisplays(displays: [primary, secondary], main: primary)
}

@Test func aPointInThePrimaryDisplayResolvesToIt() {
    let found = Display.resolve(CGPoint(x: 100, y: 100), lookup: twoDisplayLookup())
    #expect(found.id == 1)
}

@Test func aPointInTheSecondaryDisplayResolvesToIt() {
    // The secondary occupies the top-left region in CG coordinates.
    let found = Display.resolve(CGPoint(x: 100, y: 100), lookup: twoDisplayLookup())
    // 100,100 is inside the primary; pick a point that is only in the
    // secondary (negative origin).
    let foundSecondary = Display.resolve(CGPoint(x: -100, y: -100), lookup: twoDisplayLookup())
    #expect(found.id == 1)
    #expect(foundSecondary.id == 2)
}

@Test func aNegativeOriginDisplayIsFoundByCenterConversion() {
    // An AppKit frame (bottom-left origin) centered on the display whose CG
    // origin is negative. The conversion must not lose the sign, or a window
    // on the left display would be captured from the right one.
    //
    // The secondary spans CG y in [-400, 500]; its vertical center is y=50.
    // In AppKit space (bottom-left of the main display) that is
    // 700 - 50 = 650. A frame centered there, well inside the secondary.
    let appkitFrame = CGRect(x: -800, y: 600, width: 200, height: 100)
    let found = Display.display(forAppkitFrame: appkitFrame, lookup: twoDisplayLookup())
    #expect(found.id == 2)
}

@Test func aFrameOnThePrimaryResolvesToThePrimary() {
    // A frame on the main display: CG y = 700 - 150 (midY) = 550, x=200 —
    // inside the primary.
    let appkitFrame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let found = Display.display(forAppkitFrame: appkitFrame, lookup: twoDisplayLookup())
    #expect(found.id == 1)
}

@Test func aPointOnNoDisplayFallsBackToMain() {
    let lookup = SyntheticDisplays(displays: [primary], main: primary)
    // Far outside every display — the fallback must kick in, not trap.
    let found = Display.resolve(CGPoint(x: 10_000, y: 10_000), lookup: lookup)
    #expect(found.id == 1)
}

@Test func evenRoundsDownAndZeroStaysZero() {
    #expect(Screenshot.even(5) == 4)
    #expect(Screenshot.even(4) == 4)
    #expect(Screenshot.even(1) == 0)
    #expect(Screenshot.even(0) == 0)
    #expect(Screenshot.even(1024) == 1024)
}
