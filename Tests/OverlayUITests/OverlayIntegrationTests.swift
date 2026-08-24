import AppKit
import Annotation
import CoreGraphics
import Testing
@testable import OverlayUI

// End-to-end checks on the overlay: real NSEvents through the real view, then
// the pixels it actually produced. This is the layer where coordinate mistakes
// live, so it is worth driving from the outside.

@MainActor
private final class Harness {
    let window: OverlayWindow
    var view: OverlayView { window.overlayView }
    let size: CGSize

    init(_ size: CGSize = CGSize(width: 400, height: 300), scale: CGFloat = 1) {
        self.size = size
        window = OverlayWindow(displayFrame: CGRect(origin: .zero, size: size), scale: scale)
        window.overlayView.setScreenshot(Harness.image(size), scale: scale)
    }

    deinit { window.orderOut(nil) }

    /// A recognisable screenshot: a white field with a black band across the top
    /// third, so any vertical flip is obvious.
    static func image(_ size: CGSize) -> NSImage {
        let w = Int(size.width), h = Int(size.height)
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: h * 2 / 3, width: w, height: h / 3))  // CG y-up: the top third
        return NSImage(cgImage: c.makeImage()!, size: size)
    }

    /// View points (top-left origin) → window points (bottom-left origin).
    private func windowPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: size.height - p.y)
    }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags = [])
        -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: flags,
                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func drag(from a: CGPoint, to b: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, a))
        view.mouseDragged(with: event(.leftMouseDragged, b))
        view.mouseUp(with: event(.leftMouseUp, b))
    }

    func click(_ p: CGPoint) { drag(from: p, to: p) }

    func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        view.keyDown(with: e)
    }

    /// Render the view and read its pixels, y=0 at the top.
    func pixels() -> (w: Int, h: Int, data: [UInt8]) {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, data)
    }
}

// MARK: Region selection

@Test @MainActor func aDragDefinesTheRegionAndAClickClearsIt() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 250, y: 200))
    #expect(h.view.selection == CGRect(x: 50, y: 40, width: 200, height: 160))

    h.click(CGPoint(x: 300, y: 250))
    #expect(h.view.selection == nil, "a click outside is a cancel, not a 1x1 region")
}

@Test @MainActor func aBackwardsDragStillProducesAPositiveRegion() {
    let h = Harness()
    h.drag(from: CGPoint(x: 250, y: 200), to: CGPoint(x: 50, y: 40))
    #expect(h.view.selection == CGRect(x: 50, y: 40, width: 200, height: 160))
}

@Test @MainActor func theRegionCanBeMovedAndResized() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 150))

    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 120, y: 110))   // move
    #expect(h.view.selection == CGRect(x: 70, y: 60, width: 100, height: 100))

    // Grab the bottom-right handle of the moved region.
    h.drag(from: CGPoint(x: 170, y: 160), to: CGPoint(x: 200, y: 200))
    #expect(h.view.selection == CGRect(x: 70, y: 60, width: 130, height: 140))
}

@Test @MainActor func theDimmingLeavesTheRegionBrightAndTheScreenshotUpright() {
    let h = Harness()
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
    let (w, _, data) = h.pixels()
    func lum(_ x: Int, _ y: Int) -> Int { Int(data[(y * w + x) * 4]) }
    let s = w / 400   // backing scale

    // The screenshot's black band is in the top third; if the image were
    // flipped it would be at the bottom.
    #expect(lum(200 * s, 30 * s) < 140, "the top band should be dark")
    #expect(lum(200 * s, 270 * s) > 100, "the bottom should be lighter than the top")
    // Inside the region the white screenshot is undimmed; just outside it is.
    #expect(lum(200 * s, 200 * s) > lum(50 * s, 200 * s),
            "the region must be brighter than the dimmed surround")
}

// MARK: Annotating

@Test @MainActor func aToolKeyThenADragDrawsInsideTheRegion() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "r")                                    // rectangle tool
    #expect(h.view.editor.tool == .rectangle)

    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    #expect(h.view.annotations.count == 1)
    #expect(h.view.selection == CGRect(x: 50, y: 50, width: 300, height: 200),
            "annotating must not disturb the region")
}

@Test @MainActor func aDragOutsideTheRegionRedefinesItRatherThanAnnotating() {
    // The region is the subject; a drag out in the dimmed area means "I picked
    // the wrong area", not "draw a shape out there where it will be cropped off".
    let h = Harness()
    h.drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 260))
    h.key(0, "r")
    h.drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 100))
    #expect(h.view.annotations.isEmpty)
    #expect(h.view.selection == CGRect(x: 20, y: 20, width: 100, height: 80))
}

@Test @MainActor func annotationsAreClippedToTheRegion() {
    // A stroke dragged past the edge must not appear in the dimmed surround,
    // where the crop would cut it off anyway.
    let h = Harness()
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
    h.view.editor.style.color = AnnotationColor(r: 1, g: 0, b: 0)
    h.key(0, "h")                                    // highlighter, a solid fill
    h.drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 380, y: 190))

    let (w, _, data) = h.pixels()
    let s = w / 400
    func red(_ x: Int, _ y: Int) -> Bool {
        let i = ((y) * w + x) * 4
        return data[i] > 120 && data[i + 1] < 110 && data[i + 2] < 110
    }
    #expect(red(180 * s, 170 * s), "the highlight should be visible inside the region")
    #expect(!red(300 * s, 170 * s), "the highlight leaked outside the region")
}

@Test @MainActor func undoAndRedoAreWiredToTheKeyboard() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "r")
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    #expect(h.view.annotations.count == 1)

    h.key(6, "z", [.command])
    #expect(h.view.annotations.isEmpty)
    h.key(6, "z", [.command, .shift])
    #expect(h.view.annotations.count == 1)
}

@Test @MainActor func aSelectedShapeCanBeDeleted() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "r")
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    h.key(0, "s")                                    // select tool
    h.click(CGPoint(x: 150, y: 140))
    #expect(h.view.editor.selected == 0)
    h.key(51)                                        // delete
    #expect(h.view.annotations.isEmpty)
}

@Test @MainActor func strokeWidthKeysRestyleTheSelectedShape() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "r")
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    h.key(0, "s")
    h.click(CGPoint(x: 150, y: 140))
    h.key(20, "3")
    #expect(h.view.annotations[0].width == AnnotationStyle.strokeThick)
}

// MARK: Crop

@Test @MainActor func theCropToolShrinksTheRegion() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(8, "c")
    #expect(h.view.editor.tool == .crop)
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
    #expect(h.view.selection == CGRect(x: 100, y: 100, width: 100, height: 100))
    #expect(h.view.editor.tool == .select, "after cropping, dragging should not crop again")
}

@Test @MainActor func aCropIsClampedToTheExistingRegion() {
    let h = Harness()
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
    h.key(8, "c")
    h.drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 380, y: 280))
    #expect(h.view.selection == CGRect(x: 150, y: 150, width: 50, height: 50),
            "a crop cannot grow the region beyond what was captured")
}

/// A delegate that just records what it was told.
private final class Spy: OverlayViewDelegate {
    var dismissed = false
    func overlayView(_ view: OverlayView, didChangeSelection rect: CGRect?) {}
    func overlayViewDidDismiss(_ view: OverlayView) { dismissed = true }
    func overlayViewDidConfirm(_ view: OverlayView) {}
    func overlayViewDidSave(_ view: OverlayView) {}
}

// MARK: Escape

@Test @MainActor func escapeBacksOutOneLayerAtATime() {
    let h = Harness()
    let spy = Spy()
    h.view.delegate = spy

    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "r")
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    h.key(0, "s")
    h.click(CGPoint(x: 150, y: 140))
    #expect(h.view.editor.selected == 0)

    h.key(53)   // first Escape: drop the shape selection
    #expect(h.view.editor.selected == nil)
    #expect(!spy.dismissed, "the first Escape must not throw the capture away")

    h.key(53)   // second Escape: dismiss
    #expect(spy.dismissed)
}

// MARK: Text

@Test @MainActor func theTextToolOpensARealTextViewForInputMethods() {
    // A hand-rolled keyDown loop cannot do Chinese, Japanese or Korean input.
    // The presence of a live NSTextView is what makes IME work, so assert it.
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "t")
    h.click(CGPoint(x: 120, y: 120))

    let field = h.view.subviews.compactMap { $0 as? NSTextView }.first
    #expect(field != nil, "no text view: input methods would not work")
    #expect(h.view.editor.editingText == 0)

    field?.string = "hello"
    h.view.endTextEditing()
    #expect(h.view.subviews.compactMap { $0 as? NSTextView }.isEmpty)
    if case let .text(_, text) = h.view.annotations[0].kind {
        #expect(text == "hello")
    } else {
        Issue.record("expected a text annotation")
    }
}

@Test @MainActor func anEmptyTextLabelIsDiscarded() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "t")
    h.click(CGPoint(x: 120, y: 120))
    h.view.endTextEditing()
    #expect(h.view.annotations.isEmpty, "an invisible empty label is worse than nothing")
}

@Test @MainActor func typedTextIsNotDrawnTwiceWhileEditing() {
    // The text view on top already draws the glyphs; drawing the annotation's
    // text underneath as well makes it look smeared and bold.
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.key(0, "t")
    h.click(CGPoint(x: 120, y: 120))
    h.view.subviews.compactMap { $0 as? NSTextView }.first?.string = "hello"
    h.view.editor.setEditingText("hello")

    let list = h.view.renderListForTesting()
    if case let .text(_, text) = list[0].kind {
        #expect(text.isEmpty, "the annotation's own text must be suppressed while typing")
    } else {
        Issue.record("expected a text annotation")
    }
}

// MARK: One-shot tools, through the view

@Test @MainActor func returnCommitsTheLabelRatherThanTheCapture() {
    // While the text view holds first responder the overlay's keyDown never
    // runs, so without the doCommandBy hook there is no way to finish a label
    // from the keyboard at all.
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.view.editor.select(tool: .text)
    h.click(CGPoint(x: 120, y: 120))

    let field = try! #require(h.view.textViewForTesting)
    field.string = "hello"
    h.view.textDidChange(Notification(name: NSText.didChangeNotification, object: field))

    let handled = h.view.textView(field, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(handled, "Return must be consumed, not inserted as a newline")
    #expect(h.view.textViewForTesting == nil, "the label should have been committed")
    #expect(h.view.editor.tool == .select, "committing should hand the tool back")
    #expect(h.view.annotations.count == 1)
    if case let .text(_, text) = h.view.annotations[0].kind {
        #expect(text == "hello")
    } else {
        Issue.record("expected a text annotation")
    }
}

@Test @MainActor func drawingAShapeReturnsTheToolbarToSelect() {
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.view.editor.select(tool: .rectangle)
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    #expect(h.view.annotations.count == 1)
    #expect(h.view.editor.tool == .select)
}

@Test @MainActor func aSecondDragAfterDrawingMovesTheShapeInsteadOfDrawingAnother() {
    // The accident this change exists to prevent: with the tool still armed,
    // the click meant to adjust a shape drew another one on top of it.
    let h = Harness()
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.view.editor.select(tool: .rectangle)
    h.drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
    h.drag(from: CGPoint(x: 150, y: 140), to: CGPoint(x: 170, y: 160))
    #expect(h.view.annotations.count == 1, "the second drag drew a second shape")
    if case let .rect(origin, _) = h.view.annotations[0].kind {
        #expect(origin.x > 100, "the second drag should have moved it")
    }
}

@Test @MainActor func escapeDisarmsTheToolBeforeAbandoningTheCapture() {
    let h = Harness()
    let spy = Spy()
    h.view.delegate = spy
    h.drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
    h.view.editor.select(tool: .arrow)

    h.key(53)   // Escape: puts the pointer back
    #expect(h.view.editor.tool == .select)
    #expect(!spy.dismissed, "Escape must disarm before it abandons anything")

    h.key(53)   // Escape again: now there is nothing left to back out of
    #expect(spy.dismissed)
}
