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

            achieved = read()
            guard let achieved else { return (nil, attempt) }
            if Self.offset(of: achieved, from: target) <= tolerance {
                return (achieved, attempt)
            }
            if attempt < attempts { pause() }
        }
        return (achieved, attempts)
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
