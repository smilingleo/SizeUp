import AppKit
import VideoEdit

@MainActor
protocol MiniBarViewDelegate: AnyObject {
    func miniBar(_ bar: MiniBarView, didSetStart start: Int, end: Int)
    func miniBar(_ bar: MiniBarView, didScrubTo frame: Int)
    func miniBarDidTogglePulse(_ bar: MiniBarView)
    func miniBar(_ bar: MiniBarView, didInsertHold seconds: Double)
    func miniBarDidFinish(_ bar: MiniBarView)
}

/// The floating bar under the selected annotation.
///
/// It answers "when is this shape on screen?" right next to the shape itself,
/// which is the only place the question makes sense. Dragging either end retimes
/// it, clicking the track scrubs, and the two buttons are the operations that
/// belong to a selected shape rather than to the recording.
final class MiniBarView: NSView {
    weak var barDelegate: MiniBarViewDelegate?

    private var layout = MiniBarLayout(bounds: .zero)
    private var totalFrames = 1
    private var start = 0
    private var end = 0
    private var pulsing = false
    private var fps: Double = 30
    /// Frame ranges held by freeze keyframes, drawn so a hold is visible here too.
    private var freezeSpans: [(start: Int, end: Int)] = []

    private enum Drag { case none, start, end, scrub }
    private var drag = Drag.none
    private var hovering = MiniBarLayout.Hit.none

    override var isFlipped: Bool { false }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: MiniBarLayout.width,
                                height: MiniBarLayout.height))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: State

    func update(start: Int, end: Int, totalFrames: Int, fps: Double, pulsing: Bool,
                freezeSpans: [(start: Int, end: Int)]) {
        self.start = start
        self.end = end
        self.totalFrames = max(totalFrames, 1)
        self.fps = fps
        self.pulsing = pulsing
        self.freezeSpans = freezeSpans
        layout = MiniBarLayout(bounds: bounds)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layout = MiniBarLayout(bounds: bounds)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        layout = MiniBarLayout(bounds: bounds)

        // A dark pill, so the bar reads as chrome floating over the video rather
        // than as part of the picture.
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        let pill = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2,
                          cornerHeight: bounds.height / 2, transform: nil)
        ctx.addPath(pill)
        ctx.fillPath()

        let track = layout.track
        guard track.width > 0 else { return }

        // The whole recording.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: track.height / 2,
                           cornerHeight: track.height / 2, transform: nil))
        ctx.fillPath()

        // This annotation's span.
        let span = layout.spanRect(start: start, end: end, totalFrames: totalFrames)
        ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.55, blue: 1, alpha: 0.95))
        ctx.addPath(CGPath(roundedRect: span, cornerWidth: min(span.height / 2, span.width / 2),
                           cornerHeight: span.height / 2, transform: nil))
        ctx.fillPath()

        // Freeze bands last, over the span rather than under it: a hold that
        // overlaps this annotation is exactly the case worth seeing, and drawing
        // them first hid them behind the very thing they affect.
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.93, blue: 1, alpha: 0.55))
        for freeze in freezeSpans {
            let rect = layout.spanRect(start: freeze.start, end: freeze.end,
                                       totalFrames: totalFrames)
            ctx.fill(rect.insetBy(dx: 0, dy: 3))
        }

        // Handles.
        for rect in [layout.startHandle(start: start, totalFrames: totalFrames),
                     layout.endHandle(end: end, totalFrames: totalFrames)] {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2,
                               transform: nil))
            ctx.fillPath()
        }

        drawButton(ctx, layout.holdButton, title: "Hold", highlighted: hovering == .hold)
        drawButton(ctx, layout.pulseButton, title: "Pulse", highlighted: pulsing)
        drawButton(ctx, layout.doneButton, title: "Done", highlighted: hovering == .done)
    }

    private func drawButton(_ ctx: CGContext, _ rect: CGRect, title: String,
                           highlighted: Bool) {
        ctx.setFillColor(highlighted
            ? CGColor(srgbRed: 0.15, green: 0.55, blue: 1, alpha: 0.95)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4,
                           transform: nil))
        ctx.fillPath()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch layout.hit(point, start: start, end: end, totalFrames: totalFrames) {
        case .done:
            barDelegate?.miniBarDidFinish(self)
        case .pulse:
            barDelegate?.miniBarDidTogglePulse(self)
        case .hold:
            showHoldMenu(at: point)
        case .startHandle:
            drag = .start
        case .endHandle:
            drag = .end
        case .track(let frame):
            drag = .scrub
            barDelegate?.miniBar(self, didScrubTo: frame)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let frame = layout.frame(forX: point.x, totalFrames: totalFrames)
        switch drag {
        case .start:
            // A span must keep at least one frame, or the shape would be on
            // screen for no time at all and could never be found again.
            start = min(frame, end - 1 < 0 ? 0 : end - 1)
            barDelegate?.miniBar(self, didSetStart: start, end: end)
        case .end:
            end = max(frame, start + 1)
            barDelegate?.miniBar(self, didSetStart: start, end: end)
        case .scrub:
            barDelegate?.miniBar(self, didScrubTo: frame)
        case .none:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        needsDisplay = true
    }

    private func showHoldMenu(at point: CGPoint) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for seconds in MiniBarLayout.holdChoices {
            let title = seconds == 1 ? "Hold 1 second" : "Hold \(Int(seconds)) seconds"
            let item = NSMenuItem(title: title, action: #selector(holdChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: layout.holdButton.minX, y: layout.holdButton.maxY + 4),
                   in: self)
    }

    @objc private func holdChosen(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        barDelegate?.miniBar(self, didInsertHold: seconds)
    }
}
