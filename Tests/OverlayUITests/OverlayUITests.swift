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

/// A test image whose top half is red and bottom half blue. CGImage rows run
/// top→bottom, so row 0 is the visual top.
private func halfRedHalfBlue(_ n: Int) -> CGImage {
    var px = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n {
        for x in 0..<n {
            let i = (y * n + x) * 4
            if y < n / 2 { px[i] = 255; px[i + 3] = 255 } else { px[i + 2] = 255; px[i + 3] = 255 }
        }
    }
    let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@Test @MainActor func orientationIsUpright() {
    // The overlay view is flipped (top-left origin, matching Rust). Of the
    // three ways to put an image on screen, only `draw(in:)` compensates for
    // that; the composite variant and CGContext.draw both mirror it. A
    // mirrored overlay is not just cosmetic — the user drags over what they
    // see, so the copied crop comes from the mirrored half. This renders the
    // view offscreen and checks the image's top stays on top.
    let n = 40
    let window = OverlayWindow(displayFrame: CGRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n)),
                               scale: 1)
    defer { window.orderOut(nil) }
    let view = window.overlayView
    view.setScreenshot(NSImage(cgImage: halfRedHalfBlue(n), size: NSSize(width: n, height: n)),
                       scale: 1)

    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)

    // Sample in the rep's own pixel space — on a Retina backing store it is
    // larger than the view's point size, and sampling in points lands both
    // probes inside the top half (which is how this test first fooled itself).
    let px = rep.pixelsWide, py = rep.pixelsHigh
    let top = rep.colorAt(x: px / 2, y: py / 4)!.usingColorSpace(.deviceRGB)!
    let bottom = rep.colorAt(x: px / 2, y: py * 3 / 4)!.usingColorSpace(.deviceRGB)!
    #expect(top.redComponent > top.blueComponent, "overlay is upside down: top should be red")
    #expect(bottom.blueComponent > bottom.redComponent, "overlay is upside down: bottom should be blue")
}
