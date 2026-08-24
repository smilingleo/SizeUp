import CoreGraphics
import Foundation

/// Applies a frame and reads back what the window actually took.
///
/// This is deliberately one pass. It writes position, size, position — the order
/// that has always shipped — and then reads, so the caller and the log can say
/// "asked for this, got that" instead of assuming. That is the whole of it.
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
/// writes put it at risk for the sake of one that never complies either way. So
/// the sequence is exactly what it was before the investigation, and everything
/// learned from the investigation lives in `WindowProbe` and `WriteOrderProbe`,
/// which run only when asked and touch nothing otherwise.
///
/// What is kept from the episode is the read-back and the arithmetic for judging
/// it, because those changed no behaviour and turned "Slack does not resize"
/// into numbers.
///
/// A separate type from `AXWindow` because `AXWindow` needs a real
/// `AXUIElement` and cannot be tested, whereas how close counts as close enough
/// is arithmetic that can be. The writes and the read are injected.
struct FrameApplier {
    /// Reads the window's current frame, in the same space as the target.
    var read: () -> CGRect?
    var writePosition: (CGPoint) -> Void
    var writeSize: (CGSize) -> Void

    /// A point, not exact equality: Accessibility positions are integral and a
    /// tiled frame need not be, so an honest application still lands a fraction
    /// of a point away and must not be mistaken for a stubborn one.
    var tolerance: CGFloat = 1

    /// The frame the window ended up with, or `nil` if it could not be read.
    func apply(_ target: CGRect) -> CGRect? {
        // Position, size, position. The trailing position write is not
        // redundant: an application that clamps the size leaves the window where
        // the clamp put it, not where it was asked to go.
        writePosition(target.origin)
        writeSize(target.size)
        writePosition(target.origin)
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
