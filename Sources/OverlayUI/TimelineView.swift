import AppKit
import VideoEdit

/// What the timeline reports back to the window.
@MainActor
public protocol TimelineDelegate: AnyObject {
    /// The playhead was dragged or clicked to a frame.
    func timelineDidScrub(to frame: Int)
    /// A lane was clicked, selecting that annotation.
    func timelineDidSelect(annotation index: Int)
    /// An annotation's span was dragged by an edge handle.
    func timelineDidRetime(annotation index: Int, start: Int, end: Int?)
}

/// The scrubber, the annotation lanes, and the freeze bands.
///
/// One view rather than three, because all three are the same horizontal
/// mapping from frame to x — splitting them would mean keeping three copies of
/// that conversion in step, and a timeline whose parts disagree by a pixel is
/// worse than one that is slightly plain.
public final class TimelineView: NSView {
    public weak var timelineDelegate: TimelineDelegate?

    /// The document being drawn. Set by the window on every change.
    public var edit: RecordingEdit? {
        didSet { needsDisplay = true }
    }
    /// The selected annotation, drawn highlighted.
    public var selectedIndex: Int? {
        didSet { needsDisplay = true }
    }

    // Layout, matching the Rust editor's proportions.
    static let scrubberHeight: CGFloat = 24
    static let padding: CGFloat = 8
    static let lanesHeight: CGFloat = 72
    static let laneHeight: CGFloat = 5
    static let laneGap: CGFloat = 13
    static let handleWidth: CGFloat = 8
    static let handleHeight: CGFloat = 13
    public static let totalHeight: CGFloat =
        scrubberHeight + lanesHeight + padding * 3

    /// What a drag in progress is doing.
    private enum Drag {
        case none
        case scrubbing
        /// Dragging one edge of an annotation's span.
        case retiming(index: Int, edge: Edge)
    }
    private enum Edge { case start, end }
    private var drag: Drag = .none

    public override var isFlipped: Bool { true }

    // MARK: Geometry

    private var scrubberRect: CGRect {
        CGRect(x: Self.padding, y: Self.padding,
               width: max(bounds.width - Self.padding * 2, 1),
               height: Self.scrubberHeight)
    }

    private var lanesRect: CGRect {
        CGRect(x: Self.padding, y: scrubberRect.maxY + Self.padding,
               width: max(bounds.width - Self.padding * 2, 1),
               height: Self.lanesHeight)
    }

    /// Frame -> x, in view coordinates.
    private func x(forFrame frame: Int) -> CGFloat {
        guard let edit, edit.totalFrames > 1 else { return scrubberRect.minX }
        let t = Double(frame) / Double(edit.totalFrames - 1)
        return scrubberRect.minX + CGFloat(t) * scrubberRect.width
    }

    /// x -> frame, clamped to the video.
    private func frame(forX x: CGFloat) -> Int {
        guard let edit, edit.totalFrames > 1 else { return 0 }
        let t = (x - scrubberRect.minX) / max(scrubberRect.width, 1)
        return min(max(Int((Double(t) * Double(edit.totalFrames - 1)).rounded()), 0),
                   edit.totalFrames - 1)
    }

    /// The vertical band an annotation's span is drawn in.
    ///
    /// Lanes are assigned round-robin rather than packed, so an annotation stays
    /// in the same lane as others come and go — a lane that reshuffles on every
    /// edit is impossible to aim at.
    private func laneY(_ index: Int) -> CGFloat {
        let lanes = max(Int(Self.lanesHeight / Self.laneGap), 1)
        return lanesRect.minY + CGFloat(index % lanes) * Self.laneGap + 4
    }

    private func spanRect(_ timed: TimedAnnotation, index: Int) -> CGRect {
        guard let edit else { return .zero }
        let start = x(forFrame: timed.range.start)
        let end = x(forFrame: timed.range.end ?? edit.totalFrames - 1)
        return CGRect(x: start, y: laneY(index),
                      width: max(end - start, 2), height: Self.laneHeight)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let edit else { return }

        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(bounds)

        drawScrubber(context, edit)
        drawFreezeBands(context, edit)
        drawLanes(context, edit)
        drawPlayhead(context, edit)
    }

    private func drawScrubber(_ context: CGContext, _ edit: RecordingEdit) {
        let track = CGRect(x: scrubberRect.minX,
                           y: scrubberRect.midY - 3,
                           width: scrubberRect.width, height: 6)
        context.setFillColor(CGColor(gray: 0.28, alpha: 1))
        context.fill(track)

        // Elapsed portion, so the position reads without hunting for the
        // playhead.
        let played = CGRect(x: track.minX, y: track.minY,
                            width: max(x(forFrame: edit.currentFrame) - track.minX, 0),
                            height: track.height)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.55, blue: 1, alpha: 1))
        context.fill(played)
    }

    private func drawFreezeBands(_ context: CGContext, _ edit: RecordingEdit) {
        // Drawn across the whole height, behind the lanes: a freeze affects the
        // entire timeline at that point, not one annotation.
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 0.16))
        for span in edit.freezeSpans() {
            let start = x(forFrame: span.start)
            let end = x(forFrame: span.end)
            context.fill(CGRect(x: start, y: scrubberRect.minY,
                                width: max(end - start, 2),
                                height: lanesRect.maxY - scrubberRect.minY))
        }
    }

    private func drawLanes(_ context: CGContext, _ edit: RecordingEdit) {
        for (index, timed) in edit.annotations.enumerated() {
            let rect = spanRect(timed, index: index)
            let colour = timed.annotation.color
            let isSelected = index == selectedIndex

            context.setFillColor(colour.cgColor(alpha: isSelected ? 1 : 0.55))
            context.fill(rect)

            if timed.pulses {
                // A yellow cap marks a pulsing annotation, the same yellow the
                // glow uses, so the timeline and the canvas agree.
                context.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.08, alpha: 0.9))
                context.fill(CGRect(x: rect.minX, y: rect.minY - 2, width: rect.width, height: 2))
            }

            guard isSelected else { continue }
            // Grab handles, only on the selection: drawing them on every span
            // would leave no room for the spans themselves.
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            for edgeX in [rect.minX, rect.maxX] {
                context.fill(CGRect(x: edgeX - Self.handleWidth / 2,
                                    y: rect.midY - Self.handleHeight / 2,
                                    width: Self.handleWidth, height: Self.handleHeight))
            }
        }
    }

    private func drawPlayhead(_ context: CGContext, _ edit: RecordingEdit) {
        let playheadX = x(forFrame: edit.currentFrame)
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: playheadX - 1, y: scrubberRect.minY - 2,
                            width: 2, height: lanesRect.maxY - scrubberRect.minY + 4))
        // A knob on the scrubber, so it can be found and grabbed.
        context.fillEllipse(in: CGRect(x: playheadX - 6, y: scrubberRect.midY - 6,
                                       width: 12, height: 12))
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let edit else { return }

        // A handle on the selected span wins over scrubbing: the handles sit on
        // top of the lanes and are small, so anything else makes them unusable.
        if let index = selectedIndex, edit.annotations.indices.contains(index) {
            let rect = spanRect(edit.annotations[index], index: index)
            let hit = rect.insetBy(dx: -Self.handleWidth, dy: -Self.handleHeight / 2)
            if hit.contains(point) {
                if abs(point.x - rect.minX) <= Self.handleWidth {
                    drag = .retiming(index: index, edge: .start)
                    return
                }
                if abs(point.x - rect.maxX) <= Self.handleWidth {
                    drag = .retiming(index: index, edge: .end)
                    return
                }
            }
        }

        // Clicking a span selects it.
        if lanesRect.insetBy(dx: 0, dy: -4).contains(point) {
            for (index, timed) in edit.annotations.enumerated().reversed() {
                let hit = spanRect(timed, index: index)
                    .insetBy(dx: 0, dy: -(Self.laneGap - Self.laneHeight) / 2)
                if hit.contains(point) {
                    timelineDelegate?.timelineDidSelect(annotation: index)
                    return
                }
            }
        }

        drag = .scrubbing
        timelineDelegate?.timelineDidScrub(to: frame(forX: point.x))
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case .scrubbing:
            timelineDelegate?.timelineDidScrub(to: frame(forX: point.x))
        case let .retiming(index, edge):
            guard let edit, edit.annotations.indices.contains(index) else { return }
            let range = edit.annotations[index].range
            let dragged = frame(forX: point.x)
            switch edge {
            case .start:
                // Never past its own end: an inverted span would vanish and could
                // not be grabbed again to fix.
                let limit = (range.end ?? edit.totalFrames) - 1
                timelineDelegate?.timelineDidRetime(annotation: index,
                                                    start: min(dragged, limit),
                                                    end: range.end)
            case .end:
                timelineDelegate?.timelineDidRetime(annotation: index,
                                                    start: range.start,
                                                    end: max(dragged, range.start + 1))
            }
        }
    }

    public override func mouseUp(with event: NSEvent) {
        drag = .none
    }

    // MARK: Test seams

    /// The x a frame is drawn at. Exposed so the mapping can be tested without
    /// synthesising mouse events.
    public func xForFrameForTesting(_ frame: Int) -> CGFloat { x(forFrame: frame) }
    public func frameForXForTesting(_ x: CGFloat) -> Int { frame(forX: x) }
    public func spanRectForTesting(_ index: Int) -> CGRect {
        guard let edit, edit.annotations.indices.contains(index) else { return .zero }
        return spanRect(edit.annotations[index], index: index)
    }
}
