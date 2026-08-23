import AppKit
import Annotation

/// What a click-drag does to the selection.
enum SelectionDragMode {
    case none
    case newSelection
    case move
    case resize(HandleKind)
}

/// Callbacks from the overlay. The session owns the window and implements this.
@MainActor
public protocol OverlayViewDelegate: AnyObject {
    /// Fired on mouse-up after the selection changed (or was cleared).
    func overlayView(_ view: OverlayView, didChangeSelection rect: CGRect?)
    /// Escape was pressed.
    func overlayViewDidDismiss(_ view: OverlayView)
    /// Return was pressed: the user confirmed the selection.
    func overlayViewDidConfirm(_ view: OverlayView)
    /// ⌘S was pressed: save the selection to a file.
    func overlayViewDidSave(_ view: OverlayView)
}

/// The capture canvas: the screenshot as background, a darkened complement,
/// and the dashed selection rectangle with eight resize handles.
///
/// Flipped coordinates (top-left origin) so model rects map 1:1 onto the
/// drawing space; the point→pixel conversion happens at the compositing
/// boundary (Task 5), matching the Rust model which is likewise in points.
///
/// C1 scope: region selection only. The annotation canvas (drawing, selecting,
/// styling shapes) lands in C2, which extends this view.
@MainActor
public final class OverlayView: NSView {
    public weak var delegate: OverlayViewDelegate?

    /// The captured screenshot, in its natural pixel size.
    private var screenshot: NSImage?
    /// The display's backing scale factor (points → pixels).
    public private(set) var scaleFactor: CGFloat = 1

    /// The current selection in view (point) coordinates, normalized.
    public private(set) var selection: CGRect?

    /// The annotations placed on the canvas.
    ///
    /// This is the seam C2 builds on: the stored shapes the canvas renders and
    /// the user can select/move/resize/style. In C1 it stays empty (the
    /// screenshot flow copies a bare crop), but the property and `attach`
    /// exist now so that when the annotation canvas lands it extends the canvas
    /// (rendering, drag, style panel) rather than the window — C2 is "the
    /// canvas, not the window."
    public private(set) var annotations: [Annotation] = []

    /// Place an annotation on the canvas. C2's tool actions call this; the view
    /// redraws. It is the one place the model and the canvas meet, so C2 finds
    /// a stable anchor here (the eleven `Annotation.Kind`s and the nine swatch
    /// colors are already the model's surface).
    public func attach(_ annotation: Annotation) {
        annotations.append(annotation)
        needsDisplay = true
    }

    private var dragMode: SelectionDragMode = .none
    private var dragStart: CGPoint = .zero
    private var originalSelection: CGRect?

    /// Tolerance for grabbing a resize handle.
    private let handleTolerance: CGFloat = 6

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func becomeFirstResponder() -> Bool { true }

    // MARK: Input surface (the C2 seam extends these, not replaces them)

    /// Install the screenshot. `scale` maps view points to the image's pixels.
    public func setScreenshot(_ image: NSImage, scale: CGFloat) {
        screenshot = image
        scaleFactor = scale
        selection = nil
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p

        guard let sel = selection else {
            dragMode = .newSelection
            selection = CGRect(origin: p, size: .zero)
            return
        }

        // Handle grab (corners + edge midpoints, in priority order).
        let norm = sel
        for (kind, point) in Self.rectangleHandles(norm) {
            if p.distance(to: point) <= handleTolerance {
                dragMode = .resize(kind)
                originalSelection = norm
                return
            }
        }
        if p.isIn(norm) {
            dragMode = .move
            originalSelection = norm
            return
        }
        dragMode = .none
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStart.x
        let dy = p.y - dragStart.y

        switch dragMode {
        case .newSelection:
            selection = CGRect(
                x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                width: abs(dx), height: abs(dy)
            )
        case .move:
            if let r = originalSelection {
                selection = r.offsetBy(dx: dx, dy: dy)
            }
        case .resize(let handle):
            if let r = originalSelection {
                selection = Self.applyRectResize(r, handle: handle, to: p)
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if var sel = selection {
            sel = sel.standardized
            // A click (sub-3pt rect) cancels the selection.
            if sel.width < 3 || sel.height < 3 {
                sel = .zero
                selection = nil
            } else {
                selection = sel
            }
        }
        dragMode = .none
        originalSelection = nil
        needsDisplay = true
        delegate?.overlayView(self, didChangeSelection: selection)
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            delegate?.overlayViewDidDismiss(self)
        case 36, 76: // Return / Enter
            delegate?.overlayViewDidConfirm(self)
        case 1 where event.modifierFlags.contains(.command): // ⌘S: save
            delegate?.overlayViewDidSave(self)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let boundsRect = bounds
        guard let screenshot else {
            NSGraphicsContext.current?.cgContext.fill(boundsRect)
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. The screenshot, scaled to fill the view (it covers all of it:
        //    the window frame is the display and both are in points).
        NSGraphicsContext.saveGraphicsState()
        screenshot.draw(in: boundsRect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let sel = selection else {
            dimEntire(context, in: boundsRect)
            return
        }

        // 2. Dim everything outside the selection.
        let full = boundsRect
        if sel.minX > full.minX { dimRect(context, full.withRect(leftEdgeTo: sel.minX)) }
        if sel.maxX < full.maxX { dimRect(context, full.withRect(rightEdgeFrom: sel.maxX)) }
        if sel.minY > full.minY { dimRect(context, full.withRect(topEdgeTo: sel.minY)) }
        if sel.maxY < full.maxY { dimRect(context, full.withRect(bottomEdgeFrom: sel.maxY)) }

        // 3. Dashed border.
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(sel)
        context.restoreGState()

        // 5. Handles.
        for (_, point) in Self.rectangleHandles(sel) {
            let h: CGFloat = 6
            let handleRect = CGRect(x: point.x - h / 2, y: point.y - h / 2, width: h, height: h)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(handleRect)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1)
            context.stroke(handleRect)
        }

        // 6. Size badge (pixel dimensions — that's what the capture will be).
        let w = Int(sel.width * scaleFactor)
        let h = Int(sel.height * scaleFactor)
        drawSizeBadge(context, "\(w) × \(h)", near: sel, in: boundsRect)
    }

    private func dimEntire(_ context: CGContext, in rect: CGRect) {
        dimRect(context, rect)
    }

    private func dimRect(_ context: CGContext, _ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private func drawSizeBadge(_ context: CGContext, _ text: String, near sel: CGRect, in bounds: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        var x = sel.midX - textSize.width / 2
        var y = sel.minY - textSize.height - 6
        if y < 0 { y = sel.maxY + 6 } // no room above → below
        x = min(max(0, x), bounds.maxX - textSize.width)
        y = min(max(0, y), bounds.maxY - textSize.height)
        let pad: CGFloat = 4
        let badge = CGRect(x: x - pad, y: y - pad, width: textSize.width + pad * 2, height: textSize.height + pad * 2)
        context.setFillColor(NSColor(white: 0, alpha: 0.75).cgColor)
        let path = CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.fillPath()
        (text as NSString).draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad), withAttributes: attributes)
    }

    /// The eight selection handles (corners + edge midpoints).
    static func rectangleHandles(_ r: CGRect) -> [(HandleKind, CGPoint)] {
        Annotation.rectHandles(r)
    }

    static func applyRectResize(_ r: CGRect, handle: HandleKind, to point: CGPoint) -> CGRect {
        Annotation.applyRectResize(r, handle: handle, to: point)
    }
}

extension CGRect {
    func withRect(leftEdgeTo x: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY, width: x - minX, height: height)
    }
    func withRect(rightEdgeFrom x: CGFloat) -> CGRect {
        CGRect(x: x, y: minY, width: maxX - x, height: height)
    }
    func withRect(topEdgeTo y: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY, width: width, height: y - minY)
    }
    func withRect(bottomEdgeFrom y: CGFloat) -> CGRect {
        CGRect(x: minX, y: y, width: width, height: maxY - y)
    }
}

/// A borderless window that can still become key, so the overlay receives
/// keyboard input (Escape/Return) while borderless.
@MainActor
public final class OverlayWindow: NSWindow {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    private let view: OverlayView

    public init(displayFrame: CGRect, scale: CGFloat) {
        view = OverlayView(frame: displayFrame)
        super.init(
            contentRect: displayFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        contentView = view
        // The Rust app used level 102; `overlayWindow` is 102 (probe ✓).
        level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.overlayWindow.rawValue))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .black
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        view.setScreenshot(NSImage(), scale: scale) // cleared on the real one
    }

    /// The view backing the window.
    public var overlayView: OverlayView { view }

    /// Show and take key status (this is what routes Escape/Return to it).
    public func present() {
        makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
    }
}
