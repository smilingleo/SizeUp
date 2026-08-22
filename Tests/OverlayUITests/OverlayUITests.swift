import AppKit
import CoreGraphics
import Testing
@testable import OverlayUI

// `OverlayUI` is AppKit (a window), so the interaction behavior rides the
// manual checklist; what is covered here is construction and the pure
// invariants: window level, keyability, and the view's API surface.

@Test func theOverlayLevelIsTheOverlayWindowLevel() {
    // 102, probe-measured: above the menu bar (24), status items (25), and
    // normal windows (0); the same level the Rust ClipShot overlay used.
    #expect(OverlayUI.windowLevel == CGWindowLevelForKey(.overlayWindow))
}

@Test @MainActor func aWindowIsBorderlessKeyableAndAtLevel102() {
    let window = OverlayWindow(displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 2)
    defer { window.orderOut(nil) }

    #expect(window.canBecomeKey)
    #expect(!window.styleMask.contains(.titled))
    #expect(window.level.rawValue == Int(CGWindowLevelKey.overlayWindow.rawValue))
    #expect(window.contentView === window.overlayView)
    // The empty placeholder screenshot dims everything until the real one
    // arrives; the selection is empty.
    #expect(window.overlayView.selection == nil)
}

@Test @MainActor func setScreenshotRecordsScaleAndClearsSelection() {
    let window = OverlayWindow(displayFrame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2)
    defer { window.orderOut(nil) }

    let view = window.overlayView
    // The placeholder screenshot already carries the display scale passed in.
    #expect(view.scaleFactor == 2)
    view.setScreenshot(NSImage(), scale: 3)
    #expect(view.scaleFactor == 3)
    #expect(view.selection == nil)
}
