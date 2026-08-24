import CoreGraphics
import Foundation

/// Applies a frame and checks that it took, retrying a bounded number of times.
///
/// The check is the point; the retry is the cheap part of it.
///
/// Position and size are two separate Accessibility writes and an application
/// may honour one and drop the other, so a single unverified write is optimism.
/// This type replaces it with a read-back, which is what lets the caller — and
/// the log — say "asked for this, got that" instead of assuming.
///
/// It does not fix a determined refusal, and one is on record. Slack (Chromium)
/// asked to become 1120x1860 on a 3360x1860 display ignored the size write
/// entirely — not clamped to a height it liked, *ignored*, with the width
/// unchanged too. Its height was 1290 in all forty logged lines, on both
/// displays, and 1290 is the usable height of the *other*, smaller display.
/// Other applications' windows were 1860 tall on that same display at the same
/// moment, so the display was not the constraint. The position write took every
/// time; only the size did not.
///
/// Retrying was written first on the theory that the application validated the
/// size against the display it believed the window was on, and that moving it
/// first would fix the belief. The log refutes that: in the failing line the
/// Accessibility position did change and the size still did not follow.
/// `FrameApplierTests` keeps that refutation as a test, because it is the reason
/// not to reach for the same idea again.
///
/// So the retry stays for what it is honestly worth — a window that is merely
/// slow, or that clamps and then needs repositioning, costs nothing to ask twice
/// — and this type is the seam where a per-application workaround would go if
/// one is ever found.
///
/// A separate type from `AXWindow` because `AXWindow` needs a real
/// `AXUIElement` and cannot be tested, whereas every interesting decision here
/// — how many times, how close is close enough, when to give up — is arithmetic
/// that can be. The three writes and the read are injected.
struct FrameApplier {
    /// Reads the window's current frame, in the same space as the target.
    var read: () -> CGRect?
    var writePosition: (CGPoint) -> Void
    var writeSize: (CGSize) -> Void

    /// Between attempts, to let the application process the move it was just
    /// given. Injected so tests do not sleep.
    ///
    /// 10ms, up to twice: this runs on the main thread inside a hotkey handler,
    /// so the ceiling matters more than the certainty. 20ms worst case is
    /// imperceptible, and it is only ever paid by a window that did not do as it
    /// was told — a cooperative application returns after the first attempt
    /// having waited for nothing.
    var pause: () -> Void = { usleep(10_000) }

    var attempts = 3

    /// A point, not exact equality: Accessibility positions are integral and a
    /// tiled frame need not be, so an honest application still lands a fraction
    /// of a point away and must not be mistaken for a stubborn one.
    var tolerance: CGFloat = 1

    /// The frame the window ended up with, or `nil` if it could not be read.
    ///
    /// Returns after the first attempt that lands within `tolerance`, so the
    /// common case costs exactly what it did before this type existed.
    func apply(_ target: CGRect) -> (frame: CGRect?, attemptsUsed: Int) {
        var achieved: CGRect?
        for attempt in 1...max(1, attempts) {
            // Position, size, position. The trailing position write is not
            // redundant: an application that clamps the size leaves the window
            // where the clamp put it, not where it was asked to go.
            writePosition(target.origin)
            writeSize(target.size)
            writePosition(target.origin)

            guard let immediate = read() else { return (nil, attempt) }
            achieved = immediate
            if Self.offset(of: immediate, from: target) <= tolerance {
                return (immediate, attempt)
            }

            // Look again after a pause. An application relayouts on its own
            // schedule, so an immediate read can catch a frame it is still
            // moving through rather than the one it settles on — which is how a
            // window that did as it was told gets logged as one that did not.
            //
            // Only on the mismatching path, so a cooperative window still pays
            // nothing: it returned above.
            pause()
            guard let settled = read() else { return (nil, attempt) }
            achieved = settled
            if Self.offset(of: settled, from: target) <= tolerance {
                return (settled, attempt)
            }
        }

        return (settle(at: target, having: achieved), attempts)
    }

    /// Places a window that would not take the size it was asked for.
    ///
    /// Once the size is known to be refused, insisting on it is what does the
    /// damage. Slack, asked five times to be 1860 tall at one fixed origin,
    /// came to rest at five different positions — each rejected resize left it
    /// recovering wherever. The very next request, for the size it already had,
    /// was honoured to the point.
    ///
    /// So this stops asking. One position write with the size left out of it,
    /// which puts the window at the target's origin — the top-left of the region
    /// it was sent to, since Accessibility positions the top edge. A window that
    /// cannot fill its half of the display at least lands neatly in it, in the
    /// same place every time, instead of somewhere new on every keypress.
    ///
    /// Predictability is the whole benefit, and it is worth being plain that it
    /// is the only one: the window is still the wrong size and nothing here can
    /// change that.
    private func settle(at target: CGRect, having achieved: CGRect?) -> CGRect? {
        guard let achieved,
              abs(achieved.width - target.width) > tolerance
                  || abs(achieved.height - target.height) > tolerance
        else { return achieved }

        writePosition(target.origin)
        pause()
        return read() ?? achieved
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
