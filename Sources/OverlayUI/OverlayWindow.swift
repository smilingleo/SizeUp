import AppKit
import Annotation
import Capture

/// What a click-drag does to the region selection.
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
    /// Return/Enter was pressed — copy the crop.
    func overlayViewDidConfirm(_ view: OverlayView)
    /// ⌘S was pressed — save the crop to a file.
    func overlayViewDidSave(_ view: OverlayView)
    /// The editor state changed, so a toolbar should refresh.
    func overlayViewDidChangeEditor(_ view: OverlayView)
}

public extension OverlayViewDelegate {
    func overlayViewDidChangeEditor(_ view: OverlayView) {}
}

/// The full-display capture surface: the frozen screenshot, the region
/// selection, and the annotation canvas on top of it.
///
/// The view is flipped (top-left origin) to match the Rust original, so every
/// coordinate here — selection, annotations, handles — is top-left based and
/// needs no conversion when it reaches the image.
public final class OverlayView: NSView {
    public weak var delegate: OverlayViewDelegate?

    private var screenshot: NSImage?
    /// Kept alongside the NSImage so the blur tool can sample real pixels.
    private var screenshotImage: CGImage?

    /// The display's backing scale factor (points → pixels).
    public private(set) var scaleFactor: CGFloat = 1

    /// The current selection in view (point) coordinates, normalized.
    public private(set) var selection: CGRect?

    /// The annotation canvas: shapes, tool, style, selection and undo history.
    ///
    /// The editor is a pure state machine, so the interesting behaviour is
    /// tested without a window; this view only turns events into calls on it
    /// and draws the result.
    public var editor = Editor()

    private var dragMode: SelectionDragMode = .none
    private var dragStart: CGPoint = .zero
    private var originalSelection: CGRect?
    /// True while the drag belongs to the editor rather than to the region.
    private var editorOwnsDrag = false

    private var textView: NSTextView?

    /// Tolerance for grabbing a resize handle.
    private let handleTolerance: CGFloat = 6

    public init(frame: NSRect, scale: CGFloat = 1) {
        scaleFactor = scale
        super.init(frame: frame)
        wantsLayer = true
    }

    public override convenience init(frame: NSRect) {
        self.init(frame: frame, scale: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func resetCursorRects() {
        // A crosshair while a drawing tool is armed, an arrow for select. The
        // pointer is the only thing telling the user which tool is live once
        // their eyes are on the screenshot rather than the toolbar.
        discardCursorRects()
        addCursorRect(bounds, cursor: editor.tool == .select ? .arrow : .crosshair)
    }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func becomeFirstResponder() -> Bool { true }

    // MARK: Setup

    /// Install the screenshot. `scale` maps view points to the image's pixels.
    public func setScreenshot(_ image: NSImage, scale: CGFloat) {
        screenshot = image
        screenshotImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        scaleFactor = scale
        selection = nil
        editor.reset()
        endTextEditing()
        needsDisplay = true
    }

    /// Place an annotation on the canvas directly (used by tests and by any
    /// caller that wants to seed the canvas).
    public func attach(_ annotation: Annotation) {
        editor.append(annotation)
        needsDisplay = true
    }

    public var annotations: [Annotation] { editor.annotations }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        endTextEditing()

        // No region yet: the first drag defines it, and there is nothing to
        // annotate until it exists.
        guard let sel = selection else {
            editorOwnsDrag = false
            dragMode = .newSelection
            selection = CGRect(origin: p, size: .zero)
            return
        }

        // Annotations live inside the region. A click outside it is about the
        // region, never about the canvas.
        if sel.insetBy(dx: -handleTolerance, dy: -handleTolerance).contains(p) {
            if editor.pointerDown(at: p) {
                editorOwnsDrag = true
                dragMode = .none
                if editor.editingText != nil { beginTextEditing() }
                notifyEditorChanged()
                needsDisplay = true
                return
            }
        }
        editorOwnsDrag = false

        // Handle grab (corners + edge midpoints, in priority order).
        for (kind, point) in Self.rectangleHandles(sel) {
            if p.distance(to: point) <= handleTolerance {
                dragMode = .resize(kind)
                originalSelection = sel
                return
            }
        }

        if sel.contains(p) {
            dragMode = .move
            originalSelection = sel
            return
        }

        // Outside: start over.
        dragMode = .newSelection
        selection = CGRect(origin: p, size: .zero)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if editorOwnsDrag {
            editor.pointerDragged(to: p)
            needsDisplay = true
            return
        }

        switch dragMode {
        case .none:
            break
        case .newSelection:
            selection = Annotation.normalizeRect(
                dragStart, CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y))
        case .move:
            guard let original = originalSelection else { break }
            selection = original.offsetBy(dx: p.x - dragStart.x, dy: p.y - dragStart.y)
        case let .resize(kind):
            guard let original = originalSelection else { break }
            selection = Annotation.applyRectResize(original, handle: kind, to: p)
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if editorOwnsDrag {
            if let crop = editor.pointerUp(at: p) {
                applyCrop(crop)
            }
            editorOwnsDrag = false
            if editor.editingText != nil { beginTextEditing() }
            notifyEditorChanged()
            needsDisplay = true
            return
        }

        // A click, not a drag, clears the region.
        if case .newSelection = dragMode, let sel = selection,
           sel.width < 3 || sel.height < 3 {
            selection = nil
        }
        dragMode = .none
        originalSelection = nil
        needsDisplay = true
        delegate?.overlayView(self, didChangeSelection: selection)
    }

    /// Cropping shrinks the region; annotations keep their coordinates.
    private func applyCrop(_ crop: CGRect) {
        let clamped = selection?.intersection(crop) ?? crop
        guard clamped.width >= 5, clamped.height >= 5 else { return }
        selection = clamped
        editor.select(tool: .select)
        delegate?.overlayView(self, didChangeSelection: selection)
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let command = flags.contains(.command)

        switch event.keyCode {
        case 53: // Escape
            // Escape backs out one layer at a time rather than throwing the
            // capture away: first text entry, then a selected shape, then the
            // whole overlay.
            if textView != nil {
                endTextEditing()
                return
            }
            if editor.selected != nil {
                editor.clearSelection()
                notifyEditorChanged()
                needsDisplay = true
                return
            }
            delegate?.overlayViewDidDismiss(self)
            return

        case 36, 76: // Return / Enter
            delegate?.overlayViewDidConfirm(self)
            return

        case 51, 117: // Delete / Forward delete
            if editor.selected != nil {
                editor.deleteSelected()
                notifyEditorChanged()
                needsDisplay = true
                return
            }

        case 6 where command: // ⌘Z / ⇧⌘Z
            if flags.contains(.shift) { editor.redo() } else { editor.undo() }
            notifyEditorChanged()
            needsDisplay = true
            return

        case 1 where command: // ⌘S
            delegate?.overlayViewDidSave(self)
            return

        default:
            break
        }

        // Unmodified letters pick a tool; digits pick a stroke width. Both are
        // ignored while typing, where they are just text.
        guard !command, !flags.contains(.control), !flags.contains(.option),
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              let key = characters.first
        else {
            super.keyDown(with: event)
            return
        }

        if let tool = Tool.allCases.first(where: { $0.shortcutKey == key }) {
            editor.select(tool: tool)
            notifyEditorChanged()
            needsDisplay = true
            return
        }
        if let digit = key.wholeNumberValue, (1...3).contains(digit) {
            editor.style.width = AnnotationStyle.strokeWidth(preset: digit - 1)
            editor.applyStyleToSelection()
            notifyEditorChanged()
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    private func notifyEditorChanged() {
        window?.invalidateCursorRects(for: self)
        delegate?.overlayViewDidChangeEditor(self)
    }

    // MARK: Text entry

    /// Put a real NSTextView over the annotation being typed into.
    ///
    /// An NSTextView rather than hand-rolled key handling, because that is what
    /// buys a caret, selection, and — the reason it matters — input methods.
    /// Typing Chinese, Japanese or Korean into a screenshot label has to work,
    /// and a keyDown-appends-a-character loop cannot do it.
    private func beginTextEditing() {
        guard textView == nil,
              let index = editor.editingText,
              editor.annotations.indices.contains(index)
        else { return }
        let annotation = editor.annotations[index]

        let frame: CGRect
        var existing = ""
        switch annotation.kind {
        case let .text(position, text):
            existing = text
            frame = CGRect(x: position.x, y: position.y,
                           width: max(240, text.measure(size: annotation.fontSize).width + 40),
                           height: max(annotation.fontSize * 1.6, 26))
        case let .callout(origin, size, _, text):
            existing = text
            let bubble = Annotation.normalizeRect(origin, size)
            frame = CGRect(x: bubble.minX + 10, y: bubble.minY + 8,
                           width: max(bubble.width - 20, 20), height: max(bubble.height - 16, 20))
        default:
            return
        }

        let view = NSTextView(frame: frame)
        view.delegate = self
        view.string = existing
        view.font = .systemFont(ofSize: annotation.fontSize)
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.insertionPointColor = .systemBlue
        if case .callout = annotation.kind {
            view.textColor = NSColor(white: 0.12, alpha: 1)
        } else {
            view.textColor = NSColor(red: annotation.color.r, green: annotation.color.g,
                                     blue: annotation.color.b, alpha: 1)
        }
        addSubview(view)
        textView = view
        window?.makeFirstResponder(view)
    }

    /// Commit what was typed and take the text view away.
    public func endTextEditing() {
        guard let view = textView else { return }
        textView = nil
        editor.setEditingText(view.string)
        view.removeFromSuperview()
        editor.endTextEditing()
        window?.makeFirstResponder(self)
        notifyEditorChanged()
        needsDisplay = true
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
        //
        // Use the one-argument `draw(in:)` — the same call Rust's `drawInRect:`
        // makes. It is the only NSImage draw that compensates for a flipped
        // view. The `draw(in:from:operation:fraction:)` variant and
        // `CGContext.draw(_:in:)` both render upside down in a flipped view,
        // which mirrored the whole overlay (and so mirrored the copied crop,
        // because the selection is taken in the coordinates the user sees).
        // `orientationIsUpright` pins this.
        NSGraphicsContext.saveGraphicsState()
        screenshot.draw(in: boundsRect)
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

        // 3. The annotations, clipped to the region so a stroke dragged past
        //    the edge cannot bleed into the dimmed surround (and cannot appear
        //    in a place the crop will not include).
        context.saveGState()
        context.clip(to: sel)
        AnnotationRenderer.draw(renderList(), in: context,
                                blurSource: screenshotImage, blurScale: scaleFactor)
        context.restoreGState()

        // 4. Dashed border.
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(sel)
        context.restoreGState()

        // 5. Region handles.
        for (_, point) in Self.rectangleHandles(sel) {
            let h: CGFloat = 6
            drawHandle(context, CGRect(x: point.x - h / 2, y: point.y - h / 2, width: h, height: h))
        }

        // 6. The selected annotation's own handles, so it can be resized.
        if let annotation = editor.selectedAnnotation {
            for (_, point) in annotation.resizeHandles() {
                let h: CGFloat = 7
                drawHandle(context, CGRect(x: point.x - h / 2, y: point.y - h / 2,
                                           width: h, height: h), accent: true)
            }
        }

        // 7. A crop in progress.
        if let crop = editor.cropDraft {
            context.saveGState()
            context.setStrokeColor(NSColor.systemYellow.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(crop)
            context.restoreGState()
        }

        let w = Int((sel.width * scaleFactor).rounded())
        let h = Int((sel.height * scaleFactor).rounded())
        drawSizeBadge(context, "\(w) × \(h)", near: sel, in: boundsRect)
    }

    /// What to draw: the committed shapes plus any live draft. The annotation
    /// being typed into has its text suppressed, because the NSTextView on top
    /// is already drawing it — otherwise every glyph renders twice and looks
    /// smeared.
    /// Exposed for tests: the suppression of in-progress text is a drawing
    /// rule that is otherwise only observable as smeared pixels.
    func renderListForTesting() -> [Annotation] { renderList() }

    private func renderList() -> [Annotation] {
        var list = editor.renderList
        if textView != nil, let index = editor.editingText, list.indices.contains(index) {
            switch list[index].kind {
            case let .text(position, _):
                list[index].kind = .text(position: position, text: "")
            case let .callout(origin, size, pointer, _):
                list[index].kind = .callout(origin: origin, size: size, pointer: pointer, text: "")
            default:
                break
            }
        }
        return list
    }

    private func drawHandle(_ context: CGContext, _ rect: CGRect, accent: Bool = false) {
        context.saveGState()
        context.setFillColor(accent ? NSColor.systemBlue.cgColor : NSColor.white.cgColor)
        context.fill(rect)
        context.setStrokeColor(NSColor(white: 0, alpha: 0.5).cgColor)
        context.setLineWidth(0.5)
        context.stroke(rect)
        context.restoreGState()
    }

    private func drawSizeBadge(_ context: CGContext, _ text: String, near sel: CGRect, in bounds: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let pad: CGFloat = 4
        var badge = CGRect(x: sel.minX, y: sel.minY - size.height - pad * 2 - 4,
                           width: size.width + pad * 2, height: size.height + pad * 2)
        // Keep it on screen: below the selection if there is no room above.
        if badge.minY < bounds.minY { badge.origin.y = sel.minY + 4 }
        badge.origin.x = min(max(badge.minX, bounds.minX), bounds.maxX - badge.width)

        context.saveGState()
        context.setFillColor(NSColor(white: 0, alpha: 0.65).cgColor)
        context.fill(badge)
        context.restoreGState()
        (text as NSString).draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad),
                                withAttributes: attributes)
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

    // MARK: Handles

    /// The eight region handles, corners first so a corner wins a tie with an
    /// edge when they overlap on a small selection.
    static func rectangleHandles(_ r: CGRect) -> [(HandleKind, CGPoint)] {
        Annotation.rectHandles(r)
    }
}

extension OverlayView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard let view = textView else { return }
        editor.setEditingText(view.string)
        needsDisplay = true
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

/// The borderless window that hosts the overlay, one per display.
public final class OverlayWindow: NSWindow {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    private let view: OverlayView

    public init(displayFrame: CGRect, scale: CGFloat) {
        view = OverlayView(frame: CGRect(origin: .zero, size: displayFrame.size), scale: scale)
        super.init(contentRect: displayFrame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        // 102: above everything ordinary, including the Dock and full-screen
        // apps. NSWindow.Level has no symbolic member for it.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.overlayWindow.rawValue))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = view
    }

    public var overlayView: OverlayView { view }

    public func present() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(view)
    }
}
