import CoreGraphics
import Foundation

/// Applies a frame and reads back what the window actually took.
///
/// This is deliberately one pass. It writes position, size, position — the order
/// that has always shipped — and then reads, so the caller and the log can say
/// "asked for this, got that" instead of assuming.
///
/// It used to do more, and the more was wrong. Chasing a report that Slack would
/// not resize, this type grew a bounded retry and then a corrective position
/// write for windows that refused a size. Both were built on readings of the log
/// that later evidence contradicted, and together they broke resizing for the
/// same application on the display where it had always worked. Neither had ever
/// been observed to fix anything on a real window; they only passed tests
/// written against doubles that encoded the very theory being tested.
///
/// The lesson is cheap to write down and was expensive to learn: a window that
/// does as it is told is the case that must not regress, and speculative extra
/// writes put it at risk for the sake of one that never complies either way.
/// The sequence is therefore still exactly what it was, and it is still one
/// pass.
///
/// What the sequence is now wrapped in is `suppressingEnhancedUserInterface`,
/// and unlike the reverted attempts it was measured before it was written. See
/// its doc for what was measured and how. Everything else learned from the
/// investigation lives in `WindowProbe` and `WriteOrderProbe`, which run only
/// when asked and touch nothing otherwise.
///
/// A separate type from `AXWindow` because `AXWindow` needs a real
/// `AXUIElement` and cannot be tested, whereas how close counts as close enough
/// is arithmetic that can be. The writes, the read, and the suppression are
/// injected.
struct FrameApplier {
    /// Reads the window's current frame, in the same space as the target.
    var read: () -> CGRect?
    var writePosition: (CGPoint) -> Void
    var writeSize: (CGSize) -> Void

    /// Runs `writes` with the owning application's "enhanced user interface"
    /// mode turned off, if it had it on, and restores it afterwards.
    ///
    /// This is the fix for Slack, and for every application like it. An
    /// application with `AXEnhancedUserInterface` set applies a frame change as
    /// an *animation*, and the two attributes are two writes: the size write
    /// lands while the animation started by the position write is still running,
    /// and the animation finishes at the size it began with. The window ends up
    /// moved but not resized — which is exactly the reported symptom, in both of
    /// its shapes (a third that will not widen to a half, a quarter that will
    /// not grow to a half).
    ///
    /// Measured, on the machine that reported it, over three transitions on each
    /// of two displays:
    ///
    ///   - `AXEnhancedUserInterface` was `true` for Slack and `false` for
    ///     Chrome, VS Code and Finder — the applications that always worked. So
    ///     reading it first is not a heuristic about Slack, it is the difference
    ///     itself, and gating on it means an application that already complies
    ///     is never touched.
    ///   - With it suppressed, all six transitions landed exactly, in 3–30ms.
    ///     With it left alone, all six moved without resizing.
    ///   - Suppressing it only *after* a refusal does not work: all six still
    ///     failed. The flag has to be off before the first write, which is also
    ///     why this wraps the writes rather than retrying them.
    ///   - Write order is not the explanation and never was. Every order was
    ///     tried against the live window (`WriteOrderProbe`), and the ones that
    ///     appeared to work were reads taken mid-animation.
    ///
    /// Default is pass-through, so a caller that has no application to ask —
    /// every test — gets the plain sequence.
    var suppressingEnhancedUserInterface: (_ writes: () -> Void) -> Void = { writes in writes() }

    /// A point, not exact equality: Accessibility positions are integral and a
    /// tiled frame need not be, so an honest application still lands a fraction
    /// of a point away and must not be mistaken for a stubborn one.
    var tolerance: CGFloat = 1

    /// The frame the window ended up with, or `nil` if it could not be read.
    func apply(_ target: CGRect) -> CGRect? {
        suppressingEnhancedUserInterface {
            // Position, size, position. The trailing position write is not
            // redundant: an application that clamps the size leaves the window
            // where the clamp put it, not where it was asked to go.
            writePosition(target.origin)
            writeSize(target.size)
            writePosition(target.origin)
        }
        // Read outside the suppression, so the value is what the window settled
        // on with its own mode restored rather than something still in flight.
        return read()
    }

    /// Whether `achieved` is close enough to `target` to count as compliance.
    func accepted(_ achieved: CGRect, as target: CGRect) -> Bool {
        Self.offset(of: achieved, from: target) <= tolerance
    }

    /// How far the worst corner or dimension is out. One number, because the
    /// caller only ever needs "did this take" and "by how much" for the log.
    static func offset(of achieved: CGRect, from target: CGRect) -> CGFloat {
        max(
            abs(achieved.minX - target.minX), abs(achieved.minY - target.minY),
            abs(achieved.width - target.width), abs(achieved.height - target.height)
        )
    }
}
