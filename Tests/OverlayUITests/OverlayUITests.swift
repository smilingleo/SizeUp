import Testing
import CoreGraphics
@testable import OverlayUI

// `OverlayUI` is AppKit (a window), so it is covered by the manual checklist
// rather than unit tests — same honesty as `AppDelegate`. This placeholder
// pins the one constant that is pure: the window level.
@Test func theOverlayLevelIsTheOverlayWindowLevel() {
    // 102, probe-measured: above the menu bar (24), status items (25), and
    // normal windows (0); the same level the Rust ClipShot overlay used.
    #expect(OverlayUI.windowLevel == CGWindowLevelForKey(.overlayWindow))
}
