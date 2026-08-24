import Annotation
import CoreGraphics
import Foundation

/// The attention pulse: an annotation that breathes and glows.
///
/// Used to draw the eye to one thing in a recording without narration. The
/// motion is a cosine, not a sawtooth, so it eases at both ends instead of
/// snapping back — a hard reset reads as a glitch rather than a pulse.
public enum PulseEffect {
    /// One breath, in seconds. Three cycles fit in it, so the visible rate is
    /// 2.5Hz: fast enough to notice, slow enough not to strobe.
    static let cycleSeconds: Double = 1.2
    /// Peak growth. Small on purpose: an annotation that swells much more looks
    /// like it is being resized.
    static let scaleAmount: CGFloat = 0.14
    static let glowBlur: CGFloat = 22

    /// Pulse strength at a frame, in 0.35...1.
    ///
    /// It never reaches zero: at zero the glow vanishes entirely and the
    /// annotation flickers between "highlighted" and "plain", which reads as a
    /// rendering fault.
    public static func strength(frame: Int, fps: Double) -> CGFloat {
        let duration = max(Int((fps * cycleSeconds).rounded()), 1)
        // `%` on a negative frame would be negative; frames are never negative,
        // but the max keeps a bad caller from inverting the curve.
        let progress = Double(max(frame, 0) % duration) / Double(duration)
        let breath = 0.5 + 0.5 * cos(progress * 2 * .pi * 3)
        return CGFloat(0.35 + breath * 0.65)
    }

    /// Draw one timed annotation at a frame, pulsing if it is set to.
    ///
    /// `blurSource` is the frame itself, needed because the blur tool samples
    /// the picture underneath it.
    public static func draw(
        _ timed: TimedAnnotation,
        stepNumber: Int = 1,
        frame: Int,
        fps: Double,
        in ctx: CGContext,
        blurSource: CGImage? = nil,
        blurScale: CGFloat = 1
    ) {
        guard timed.pulses else {
            AnnotationRenderer.draw(timed.annotation, stepNumber: stepNumber, in: ctx,
                          blurSource: blurSource, blurScale: blurScale)
            return
        }

        let amount = strength(frame: frame, fps: fps)
        let rect = timed.annotation.boundingRect()
        let center = CGPoint(x: rect.midX, y: rect.midY)

        ctx.saveGState()
        // A shadow with no offset is a glow. Yellow, because it has to read
        // against both the blue-ish annotation palette and arbitrary content.
        ctx.setShadow(offset: .zero, blur: glowBlur * max(amount, 0.2),
                      color: CGColor(srgbRed: 1, green: 0.88, blue: 0.08,
                                     alpha: 0.9 * amount))
        // Scale about the annotation's own centre, so it grows in place instead
        // of drifting toward the origin.
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1 + amount * scaleAmount, y: 1 + amount * scaleAmount)
        ctx.translateBy(x: -center.x, y: -center.y)
        AnnotationRenderer.draw(timed.annotation, stepNumber: stepNumber, in: ctx,
                      blurSource: blurSource, blurScale: blurScale)
        ctx.restoreGState()
    }

    /// Draw everything visible at `frame`, in order, with step numbers assigned
    /// the same way the screenshot editor assigns them: by position among the
    /// steps that are actually on screen.
    public static func drawAll(
        _ annotations: [TimedAnnotation],
        frame: Int,
        fps: Double,
        in ctx: CGContext,
        blurSource: CGImage? = nil,
        blurScale: CGFloat = 1
    ) {
        var step = 0
        for timed in annotations where timed.range.contains(frame) {
            if case .step = timed.annotation.kind { step += 1 }
            draw(timed, stepNumber: step, frame: frame, fps: fps, in: ctx,
                 blurSource: blurSource, blurScale: blurScale)
        }
    }
}
