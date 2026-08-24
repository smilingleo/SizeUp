import CoreGraphics
import Foundation

/// Where the parts of the per-annotation mini bar go, and what a click on it
/// means.
///
/// This is the floating bar that appears under the selected annotation: a track
/// showing the whole recording with that annotation's span marked and draggable,
/// plus the controls that only make sense for a selected shape — hold and pulse.
/// Those two used to sit permanently in the window's bottom bar, which was wrong
/// twice over: they were enabled or greyed out depending on a selection made
/// somewhere else entirely, and "hold" reads as a property of the recording
/// rather than of the moment the shape is on.
///
/// Pure geometry, no AppKit, because everything here is an off-by-one waiting to
/// happen: which pixel is which frame, and which handle a click landed on.
public struct MiniBarLayout: Equatable, Sendable {
    /// Matches the Rust original, so the bar feels the same size.
    public static let height: CGFloat = 20
    public static let width: CGFloat = 340
    /// Space between the annotation's bounding box and the bar.
    public static let gap: CGFloat = 6

    static let handleWidth: CGFloat = 6
    static let trackHeight: CGFloat = 10
    static let trackYOffset: CGFloat = 5
    static let holdButtonWidth: CGFloat = 46
    static let pulseButtonWidth: CGFloat = 46
    static let doneButtonWidth: CGFloat = 42
    static let buttonGap: CGFloat = 4

    public let bounds: CGRect

    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    // MARK: Buttons, laid out from the right

    public var doneButton: CGRect {
        CGRect(x: bounds.width - Self.doneButtonWidth - 2, y: 2,
               width: Self.doneButtonWidth, height: bounds.height - 4)
    }

    public var pulseButton: CGRect {
        CGRect(x: doneButton.minX - Self.buttonGap - Self.pulseButtonWidth, y: 2,
               width: Self.pulseButtonWidth, height: bounds.height - 4)
    }

    public var holdButton: CGRect {
        CGRect(x: pulseButton.minX - Self.buttonGap - Self.holdButtonWidth, y: 2,
               width: Self.holdButtonWidth, height: bounds.height - 4)
    }

    // MARK: Track

    /// The full-width strip representing the whole recording.
    public var track: CGRect {
        let left = Self.handleWidth + 4
        let right = holdButton.minX - Self.buttonGap
        return CGRect(x: left, y: Self.trackYOffset,
                      width: max(right - left, 0), height: Self.trackHeight)
    }

    /// x for a frame, measured across the track.
    public func x(forFrame frame: Int, totalFrames: Int) -> CGFloat {
        guard totalFrames > 1 else { return track.minX }
        let fraction = Double(min(max(frame, 0), totalFrames - 1)) / Double(totalFrames - 1)
        return track.minX + track.width * CGFloat(fraction)
    }

    /// The frame a click at `x` lands on, clamped into the recording.
    public func frame(forX x: CGFloat, totalFrames: Int) -> Int {
        guard totalFrames > 1, track.width > 0 else { return 0 }
        let fraction = Double((x - track.minX) / track.width)
        let frame = Int((fraction * Double(totalFrames - 1)).rounded())
        return min(max(frame, 0), totalFrames - 1)
    }

    /// The filled part of the track, for a span.
    public func spanRect(start: Int, end: Int, totalFrames: Int) -> CGRect {
        let x0 = x(forFrame: start, totalFrames: totalFrames)
        let x1 = x(forFrame: end, totalFrames: totalFrames)
        return CGRect(x: x0, y: track.minY, width: max(x1 - x0, 1), height: track.height)
    }

    public func startHandle(start: Int, totalFrames: Int) -> CGRect {
        let x0 = x(forFrame: start, totalFrames: totalFrames)
        return CGRect(x: x0 - Self.handleWidth / 2, y: track.minY - 2,
                      width: Self.handleWidth, height: track.height + 4)
    }

    public func endHandle(end: Int, totalFrames: Int) -> CGRect {
        let x1 = x(forFrame: end, totalFrames: totalFrames)
        return CGRect(x: x1 - Self.handleWidth / 2, y: track.minY - 2,
                      width: Self.handleWidth, height: track.height + 4)
    }

    // MARK: Hit testing

    public enum Hit: Equatable, Sendable {
        case startHandle
        case endHandle
        case track(frame: Int)
        case hold
        case pulse
        case done
        case none
    }

    /// What a press at `point` (in the bar's own coordinates) means.
    ///
    /// Handles win over the track, because they overlap it and are the smaller,
    /// harder-to-hit target. The start handle is tested first so that a
    /// zero-length span, where both sit on top of each other, can still be
    /// lengthened by dragging the end.
    public func hit(_ point: CGPoint, start: Int, end: Int, totalFrames: Int) -> Hit {
        if doneButton.contains(point) { return .done }
        if pulseButton.contains(point) { return .pulse }
        if holdButton.contains(point) { return .hold }

        let grow: CGFloat = 3
        if endHandle(end: end, totalFrames: totalFrames).insetBy(dx: -grow, dy: -grow)
            .contains(point) {
            return .endHandle
        }
        if startHandle(start: start, totalFrames: totalFrames).insetBy(dx: -grow, dy: -grow)
            .contains(point) {
            return .startHandle
        }
        if track.insetBy(dx: 0, dy: -grow).contains(point) {
            return .track(frame: frame(forX: point.x, totalFrames: totalFrames))
        }
        return .none
    }

    /// Where the bar should sit, given the annotation it belongs to.
    ///
    /// Visually below the shape by default, above it if there is no room, and
    /// always inside the canvas — a bar hanging off the edge could not be reached.
    ///
    /// Both rects are in AppKit's y-up window space, so "below" means a *smaller*
    /// y. Writing this the other way round put the bar above the shape, which is
    /// exactly where it covers what the shape is pointing at.
    public static func origin(under annotation: CGRect, in canvas: CGRect) -> CGPoint {
        var x = annotation.midX - width / 2
        x = min(max(x, canvas.minX + 4), max(canvas.maxX - width - 4, canvas.minX + 4))

        var y = annotation.minY - gap - height
        if y < canvas.minY {
            y = annotation.maxY + gap
        }
        y = min(max(y, canvas.minY + 4), max(canvas.maxY - height - 4, canvas.minY + 4))
        return CGPoint(x: x, y: y)
    }

    /// The hold durations the button offers, in seconds.
    public static let holdChoices: [Double] = [1, 2, 3, 5]
}
