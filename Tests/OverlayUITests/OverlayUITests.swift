import AppKit
import CoreGraphics
import Testing
import Annotation
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

@Test @MainActor func attachIsTheSeamC2BuildsOn() {
    // The C2 seam: the canvas holds the stored shapes and `attach` is the one
    // place the annotation model meets the view. C1 leaves the canvas empty;
    // this pins that the seam exists and records shapes, so C2 extends the
    // canvas (rendering/drag/style) rather than reinventing the window.
    let window = OverlayWindow(displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
    defer { window.orderOut(nil) }
    let view = window.overlayView

    #expect(view.annotations.isEmpty)
    let rect = Annotation(kind: .rect(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 40, height: 20)),
                          color: AnnotationColor.choices[3])
    view.attach(rect)
    #expect(view.annotations == [rect])
    view.attach(Annotation(kind: Annotation.Kind.arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 5, y: 5))))
    #expect(view.annotations.count == 2)
}
