import CoreGraphics
import Geometry
import Testing
import WindowKit
@testable import Core

/// The author's actual two-display setup, measured with `CGWindowList` and
/// `NSScreen` while diagnosing a report that Slack would not tile.
///
/// It is written down as a test because the report's evidence was a window
/// sitting on the large display at exactly the *small* display's usable size,
/// which is what tiling against the wrong screen looks like. That accusation is
/// either true or it is not, and it is cheap to settle: these are the real
/// numbers, and this is what the router does with them.
///
/// The configuration is worth keeping regardless of that bug. It is awkward in
/// three ways at once, and each one has broken a coordinate conversion
/// somewhere before: the second display is to the *left* (negative x), it is
/// mounted *higher* (its Cocoa origin y is above the primary's, so a window on
/// it has a y beyond the primary's height), and the two have different scale
/// factors, so their menu-bar insets differ (39pt against 30pt).
private let smallPrimary = ScreenInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
    visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1290)
)

private let largeLeftAndHigh = ScreenInfo(
    id: 2,
    frame: CGRect(x: -3360, y: 864, width: 3360, height: 1890),
    visibleFrame: CGRect(x: -3360, y: 864, width: 3360, height: 1860)
)

private let bothScreens = [smallPrimary, largeLeftAndHigh]

/// Slack's window as `CGWindowList` reported it: on the large display, but the
/// small display's usable size to the point.
private let slackCocoaFrame = CGRect(x: -3360, y: 864, width: 2056, height: 1290)

@MainActor
@Test func aWindowOnTheLargeDisplayIsTiledAgainstTheLargeDisplay() {
    // The whole accusation, in one assertion. A window sized like the small
    // display but sitting on the large one must still be tiled against the
    // display it is on: 3360 wide, not 2056.
    let window = TestWindow(frame: slackCocoaFrame)
    makeRouter(window: window, screens: bothScreens).perform(.fullScreen)

    #expect(window.applied == [largeLeftAndHigh.visibleFrame])
}

@MainActor
@Test func halvesOnTheLargeDisplayUseItsOwnWidthNotThePrimarys() {
    let window = TestWindow(frame: slackCocoaFrame)
    makeRouter(window: window, screens: bothScreens).perform(.half(.left))

    // Half of 3360 is 1680. Half of the primary's 2056 would be 1028, and a
    // window 1028 wide on this display is the bug this test denies.
    #expect(window.applied == [CGRect(x: -3360, y: 864, width: 1680, height: 1860)])
}

@MainActor
@Test func aWindowOnThePrimaryIsUnaffectedByTheLargerNeighbour() {
    // The other half of the claim: choosing by overlap must not simply prefer
    // the bigger display, which would pass the two tests above for the wrong
    // reason.
    let window = TestWindow(frame: CGRect(x: 100, y: 100, width: 800, height: 600))
    makeRouter(window: window, screens: bothScreens).perform(.fullScreen)

    #expect(window.applied == [smallPrimary.visibleFrame])
}

/// The Accessibility origin is the top-left of the display at Cocoa `(0, 0)`,
/// which here is the *small* display — so a window on the large one has an
/// Accessibility y of -825 and a Cocoa y of 864, and neither number appears in
/// the other space. Getting this backwards would place windows on the wrong
/// display, which is the same symptom as the bug above from a different cause.
@Test func slacksMeasuredFrameConvertsBetweenAccessibilityAndCocoa() {
    let primaryFrame = smallPrimary.frame
    // Exactly what `CGWindowList` printed for Slack's on-screen window.
    let accessibility = CGRect(x: -3360, y: -825, width: 2056, height: 1290)

    let cocoa = cocoaRect(fromAX: accessibility, primaryFrame: primaryFrame)
    #expect(cocoa == slackCocoaFrame)
    // And it is on the large display, by containment rather than by a sliver.
    #expect(largeLeftAndHigh.frame.contains(cocoa))

    #expect(axRect(fromCocoa: cocoa, primaryFrame: primaryFrame) == accessibility)
}

/// One of Slack's eight offscreen windows is the primary display's menu-bar
/// strip, 2056x39 at the Accessibility origin. If Accessibility ever offers
/// that as the focused window, the router will tile *it* — and the visible
/// window will not move, while the numbers all look reasonable in isolation.
///
/// This test does not assert a fix. It pins the arithmetic that makes the
/// hypothesis testable: full-screening that strip's display yields 2056x1290,
/// which is the size Slack's real window was found at.
@Test func theMenuBarStripBelongsToThePrimaryAndWouldTileToItsUsableSize() {
    let strip = cocoaRect(
        fromAX: CGRect(x: 0, y: 0, width: 2056, height: 39),
        primaryFrame: smallPrimary.frame
    )
    #expect(strip == CGRect(x: 0, y: 1290, width: 2056, height: 39))
    #expect(smallPrimary.frame.contains(strip))
    #expect(smallPrimary.visibleFrame.size == slackCocoaFrame.size)
}
