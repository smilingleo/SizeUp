import Annotation
import AppKit
import Capture
import VideoEdit

@MainActor
public protocol RecordingCanvasDelegate: AnyObject {
    /// The document changed: refresh the timeline, toolbar and labels.
    func canvasDidEdit(_ canvas: RecordingCanvasView)
}

/// The video frame with annotations drawn over it, and the place gestures land.
///
/// Flipped, like the capture overlay, so annotation coordinates mean the same
/// thing in both editors and the renderer needs no special case.
public final class RecordingCanvasView: NSView {
    public weak var canvasDelegate: RecordingCanvasDelegate?

    /// The document and the gesture machine.
    public var bridge: EditorBridge {
        didSet { needsDisplay = true }
    }
    /// Supplies frames. Nil until the video opens.
    public var decoder: VideoDecoder?

    /// The frame currently on screen, cached so a redraw does not decode again.
    private var displayedFrame: CGImage?
    private var displayedIndex: Int = -1

    /// Live text editing, reusing the capture overlay's approach: a real
    /// `NSTextView` so input methods and CJK work, rather than a home-made
    /// keystroke handler that would not.
    private var textView: NSTextView?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public init(bridge: EditorBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Frame geometry

    /// Where the video sits inside the view, letterboxed to preserve its shape.
    ///
    /// A stretched frame would misplace every annotation relative to what the
    /// user sees, and the export would not match the canvas.
    public var videoRect: CGRect {
        guard let decoder, decoder.pixelSize.width > 0, decoder.pixelSize.height > 0
        else { return bounds }
        let videoAspect = decoder.pixelSize.width / decoder.pixelSize.height
        let viewAspect = bounds.width / max(bounds.height, 1)
        if viewAspect > videoAspect {
            let width = bounds.height * videoAspect
            return CGRect(x: (bounds.width - width) / 2, y: 0,
                          width: width, height: bounds.height)
        }
        let height = bounds.width / videoAspect
        return CGRect(x: 0, y: (bounds.height - height) / 2,
                      width: bounds.width, height: height)
    }

    /// The coordinate space annotations are authored in: the letterboxed video
    /// area, with the origin at its top-left.
    ///
    /// Reported to the exporter so it can scale the same shapes up to video
    /// pixels.
    public var annotationSpace: CGSize { videoRect.size }

    private func toAnnotation(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - videoRect.minX, y: point.y - videoRect.minY)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(bounds)

        let source = frameImage()
        if let source {
            // `NSImage.draw(in:)` is the only variant that comes out upright in a
            // flipped view -- the same trap the capture overlay hit.
            NSImage(cgImage: source, size: videoRect.size).draw(in: videoRect)
        }

        // Annotations are authored with the video's top-left as the origin, so
        // shift into that space once and draw everything there.
        context.saveGState()
        context.translateBy(x: videoRect.minX, y: videoRect.minY)
        PulseEffect.drawAll(bridge.timedRenderList(),
                            frame: bridge.currentFrame,
                            fps: bridge.edit.fps,
                            in: context,
                            blurSource: source,
                            blurScale: 1)
        drawSelectionHandles(context)
        context.restoreGState()
    }

    /// The frame at the playhead, decoded on demand and cached.
    private func frameImage() -> CGImage? {
        guard let decoder else { return nil }
        let source = bridge.edit.sourceFrame(forTimeline: bridge.currentFrame)
        if source == displayedIndex, let displayedFrame { return displayedFrame }
        // Keep the previous picture if a frame fails to decode: a black flash
        // during a scrub looks like a corrupt recording.
        if let image = decoder.frame(at: source) {
            displayedFrame = image
            displayedIndex = source
        }
        return displayedFrame
    }

    private func drawSelectionHandles(_ context: CGContext) {
        guard let annotation = bridge.editor.selectedAnnotation else { return }
        let rect = annotation.boundingRect()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect.insetBy(dx: -3, dy: -3))
        context.setLineDash(phase: 0, lengths: [])
    }

    /// Force a decode on the next draw — after a freeze or speed change the same
    /// timeline frame maps to a different picture.
    public func invalidateFrame() {
        displayedIndex = -1
        needsDisplay = true
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEditing()
        _ = bridge.pointerDown(at: toAnnotation(convert(event.locationInWindow, from: nil)))
        notifyEdited()
    }

    public override func mouseDragged(with event: NSEvent) {
        _ = bridge.pointerDragged(to: toAnnotation(convert(event.locationInWindow, from: nil)))
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        bridge.pointerUp(at: toAnnotation(convert(event.locationInWindow, from: nil)))
        if bridge.editor.editingText != nil {
            beginTextEditing()
        }
        notifyEdited()
    }

    private func notifyEdited() {
        needsDisplay = true
        canvasDelegate?.canvasDidEdit(self)
    }

    // MARK: Text editing

    private func beginTextEditing() {
        guard textView == nil, let annotation = bridge.editor.selectedAnnotation else {
            return
        }
        let rect = annotation.boundingRect().offsetBy(dx: videoRect.minX, dy: videoRect.minY)
        let view = NSTextView(frame: rect.insetBy(dx: -2, dy: -2))
        view.isFieldEditor = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: annotation.fontSize)
        view.textColor = NSColor(cgColor: annotation.color.cgColor)
        view.delegate = self
        addSubview(view)
        window?.makeFirstResponder(view)
        textView = view
    }

    /// Commit whatever has been typed and take the text view down.
    public func endTextEditing() {
        guard let view = textView else { return }
        bridge.setEditingText(view.string)
        bridge.commitText()
        view.removeFromSuperview()
        textView = nil
        window?.makeFirstResponder(self)
        notifyEdited()
    }

    public var isEditingText: Bool { textView != nil }

    // MARK: Test seams

    public func pointForTesting(_ annotationPoint: CGPoint) -> CGPoint {
        CGPoint(x: annotationPoint.x + videoRect.minX,
                y: annotationPoint.y + videoRect.minY)
    }
}

extension RecordingCanvasView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        guard let view = textView else { return }
        bridge.setEditingText(view.string)
        needsDisplay = true
    }

    public func textView(_ view: NSTextView,
                         doCommandBy selector: Selector) -> Bool {
        // Return commits; Shift-Return inserts a newline, the same bargain the
        // capture overlay makes.
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) { return false }
            endTextEditing()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }
}
