import CoreGraphics
import Foundation

/// The recording model: frame pacing, click detection and click ripples.
///
/// All of it is pure, so the parts that decide *what* a recording contains are
/// testable without a screen, an encoder or a clock. `ScreenRecorder` is the
/// shell that supplies real frames and real time.
public enum Recording {
    /// Frames per second. Fixed rather than settable: the encoder, the pacing
    /// and the ripple duration are all expressed in frames, and a variable rate
    /// would make a click ripple's on-screen duration depend on the frame rate.
    public static let fps = 30

    /// How long a click ripple lives.
    public static let clickRippleSeconds = 0.75

    /// The ripple's life in frames — at least one, so a ripple can never be
    /// born already expired.
    public static var clickRippleFrames: Int {
        max(1, Int((Double(fps) * clickRippleSeconds).rounded()))
    }

    /// How many frames a recording of `elapsed` seconds should contain.
    ///
    /// The recorder writes frames until it has this many, repeating the last
    /// one if the capture could not keep up. That is what keeps playback the
    /// same length as the wall clock: dropping a frame without replacing it
    /// would silently speed the video up.
    public static func frameCount(forElapsed elapsed: TimeInterval) -> Int {
        max(1, Int((elapsed * Double(fps)).rounded()))
    }
}

/// One click, expanding and fading from the frame it was made on.
public struct ClickRipple: Equatable, Sendable {
    /// Where the click landed, in the recorded region's own coordinates.
    public var position: CGPoint
    /// The frame the click happened on.
    public var frame: Int

    public init(position: CGPoint, frame: Int) {
        self.position = position
        self.frame = frame
    }

    /// How far through its life this ripple is at `frame`, or `nil` if it is
    /// not alive then.
    public func progress(at frame: Int, duration: Int = Recording.clickRippleFrames) -> CGFloat? {
        guard frame >= self.frame, frame <= self.frame + duration else { return nil }
        return CGFloat(frame - self.frame) / CGFloat(duration)
    }

    /// The expanding outer ring.
    public func ringRect(at progress: CGFloat) -> CGRect {
        let radius = 10 + progress * 62
        return CGRect(x: position.x - radius, y: position.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    /// The solid dot at the point actually clicked.
    public func centerRect(at progress: CGFloat) -> CGRect {
        let radius = 5 + progress * 5
        return CGRect(x: position.x - radius, y: position.y - radius,
                      width: radius * 2, height: radius * 2)
    }
}

/// The live ripples, aged off as the recording advances.
public struct ClickRippleTrack: Equatable, Sendable {
    public private(set) var ripples: [ClickRipple] = []

    public init() {}

    public mutating func add(_ ripple: ClickRipple) {
        ripples.append(ripple)
    }

    /// Drop ripples that have finished. Without this a long recording keeps
    /// every click ever made and pays to draw all of them on every frame.
    public mutating func prune(before frame: Int,
                               duration: Int = Recording.clickRippleFrames) {
        ripples.removeAll { frame > $0.frame + duration }
    }

    public var isEmpty: Bool { ripples.isEmpty }
}

/// Turns "is a mouse button down" samples into ripple-worthy clicks.
///
/// Polled rather than event-driven, because the recorder already wakes up every
/// frame and a global event tap would need its own permission. The subtlety is
/// that polling sees a *held* button as down on every frame, so a press has to
/// be recognised as an edge, and a button held for a second must not emit
/// thirty ripples.
public struct ClickDetector: Equatable, Sendable {
    private var leftWasDown = false
    private var rightWasDown = false

    public init() {}

    /// - Returns: true if this sample is the start of a new click.
    public mutating func sample(leftDown: Bool, rightDown: Bool) -> Bool {
        let pressed = (leftDown && !leftWasDown) || (rightDown && !rightWasDown)
        leftWasDown = leftDown
        rightWasDown = rightDown
        return pressed
    }
}

/// Draws click ripples. CoreGraphics only, so the same code works against a
/// video frame's bitmap and against a test's offscreen context.
///
/// The context must be in the frame's own coordinates, y-down.
public enum ClickRippleRenderer {
    public static func draw(_ track: ClickRippleTrack, at frame: Int, in context: CGContext) {
        for ripple in track.ripples {
            draw(ripple, at: frame, in: context)
        }
    }

    public static func draw(_ ripple: ClickRipple, at frame: Int, in context: CGContext) {
        guard let progress = ripple.progress(at: frame) else { return }
        let alpha = max(0, 1 - progress)
        let ring = ripple.ringRect(at: progress)
        let center = ripple.centerRect(at: progress)

        context.saveGState()
        // The glow keeps the ripple readable over light and dark content alike.
        // Its blur floors at 0.2 so the ring does not lose its edge as it fades.
        let glow = CGColor(srgbRed: 0.05, green: 0.48, blue: 1, alpha: 0.95 * alpha)
        context.setShadow(offset: .zero, blur: 16 * max(alpha, 0.2), color: glow)

        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.48, blue: 1, alpha: 0.26 * alpha))
        context.fillEllipse(in: ring)
        context.setStrokeColor(CGColor(srgbRed: 0, green: 0.36, blue: 1, alpha: 0.98 * alpha))
        context.setLineWidth(5)
        context.strokeEllipse(in: ring)
        // A thin white ring inside the blue one, so the ripple reads against a
        // blue window too.
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72 * alpha))
        context.setLineWidth(2)
        context.strokeEllipse(in: ring)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82 * alpha))
        context.fillEllipse(in: center)
        context.restoreGState()
    }
}
