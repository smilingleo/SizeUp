import AppKit

/// A click-through red frame around the region being recorded.
///
/// Without it there is nothing on screen saying a recording is running or where
/// its edges are — the overlay is gone by then, and the only other signal is a
/// small status-bar change. It has to be click-through (`ignoresMouseEvents`),
/// because the user is meant to keep working inside the region it surrounds, and
/// it has to be excluded from the capture, or the recording contains its own
/// chrome.
public final class RecordingBorderWindow: NSWindow {
    /// The frame's thickness in points. Drawn *outside* the recorded region so
    /// it never covers a pixel the user asked to record.
    public static let borderWidth: CGFloat = 2

    private let borderView = BorderView()

    public init() {
        super.init(contentRect: .zero, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        // Above the recorded content but below the overlay, which is not up at
        // the same time anyway.
        level = OverlayLevel.overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = borderView
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Place the frame around `region`, given in the display's points with a
    /// top-left origin (the space the overlay reports a selection in).
    public func show(around region: CGRect, on displayFrame: CGRect) {
        let inset = Self.borderWidth
        // Flip into screen coordinates, then grow by the border width so the
        // frame sits outside the region rather than over its edge pixels.
        let screenRegion = CGRect(
            x: displayFrame.minX + region.minX,
            y: displayFrame.minY + (displayFrame.height - region.maxY),
            width: region.width, height: region.height)
        setFrame(screenRegion.insetBy(dx: -inset, dy: -inset), display: true)
        borderView.needsDisplay = true
        orderFront(nil)
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let width = RecordingBorderWindow.borderWidth
            context.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.setLineWidth(width)
            // Inset by half the line width: a stroke straddles its path, so
            // stroking the bounds directly would clip the outer half away.
            context.stroke(bounds.insetBy(dx: width / 2, dy: width / 2))
        }
    }
}
