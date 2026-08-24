import CoreGraphics
import Diagnostics

/// The raw Accessibility writes, in Accessibility space, without the
/// position-size-position choreography wrapped round them.
///
/// `WindowHandle.setFrame` deliberately hides this: callers should not be
/// choosing an order. `WriteOrderProbe` is the exception, because the order is
/// exactly what it is investigating.
public protocol RawFrameWriting: AnyObject {
    func readAXFrame() -> CGRect?
    func writeAXPosition(_ position: CGPoint)
    func writeAXSize(_ size: CGSize)
}

/// Tries the same frame request several different ways to find out whether the
/// order of the writes is what a window is objecting to.
///
/// Every other explanation is now exhausted. Slack accepts width writes and
/// ignores height writes, whatever the height happens to be — after a manual
/// drag to 1539 the frozen value became 1539, so it is not a display dimension
/// and not a limit, it is the height simply never changing. Accessibility calls
/// the size settable, the write returns success, the application has one
/// standard window, and dragging the bottom edge by hand works.
///
/// The one variable never varied is ours. `setFrame` always writes position,
/// size, position, and if the application's position handler re-asserts the
/// size it currently believes in, that trailing write would undo the resize —
/// invisibly, and with the width surviving only if the two attributes are
/// applied on different schedules. That is a guess, but it is a testable one,
/// which is more than the alternatives.
///
/// So: same request, several orders, one line of log each, restoring the
/// window between plans so no plan inherits another's mess. If one order works,
/// `setFrame` should adopt it. If none do, the height is not ours to change and
/// the answer is a paragraph in the README rather than more code.
public struct WriteOrderProbe {
    public enum Step: Equatable, Sendable {
        case position
        case size
        /// Let the application catch up, in case the writes are applied on
        /// different schedules and the order only matters when they overlap.
        case pause
    }

    public struct Plan: Equatable, Sendable {
        public let name: String
        public let steps: [Step]
    }

    /// Ordered so that the first plan is what ships today, giving every later
    /// line something to be compared against.
    public static let plans: [Plan] = [
        Plan(name: "position, size, position (what ClipShot does)",
             steps: [.position, .size, .position]),
        // The direct test of the suspicion: no position write after the resize.
        Plan(name: "position, size", steps: [.position, .size]),
        // No position write at all, which is the cleanest possible size write.
        Plan(name: "size alone", steps: [.size]),
        // If the size needs the window to be on the display first, a pause is
        // what separates "wrong order" from "too fast".
        Plan(name: "position, pause, size", steps: [.position, .pause, .size]),
        // Size before position, in case the application recomputes on the move.
        Plan(name: "size, position", steps: [.size, .position]),
        // Twice, with time in between: the second write is issued by a window
        // that has already seen the first.
        Plan(name: "size, pause, size", steps: [.size, .pause, .size]),
    ]

    /// Runs every plan against `target`, restoring `original` in between.
    ///
    /// Reports the achieved height per plan, because the height is the only
    /// thing in question — the width has never once been refused.
    public static func run(
        on window: RawFrameWriting,
        target: CGRect,
        original: CGRect,
        pause: () -> Void,
        describe: (String) -> Void
    ) {
        for plan in plans {
            restore(window, to: original, pause: pause)
            guard let before = window.readAXFrame() else {
                describe("write order: cannot read the frame before \(plan.name)")
                continue
            }

            for step in plan.steps {
                switch step {
                case .position: window.writeAXPosition(target.origin)
                case .size: window.writeAXSize(target.size)
                case .pause: pause()
                }
            }
            // Always read after a settle: an immediate read can catch a frame
            // the window is still moving through, and that would score plans on
            // their timing rather than their order.
            pause()

            guard let after = window.readAXFrame() else {
                describe("write order: \(plan.name) — frame unreadable afterwards")
                continue
            }
            let verdict = abs(after.height - target.height) <= 1
                ? "TOOK THE HEIGHT"
                : "height unchanged at \(Int(after.height))"
            describe("write order: \(plan.name) — asked for height"
                + " \(Int(target.height)) from \(Int(before.height)), \(verdict)"
                + " (width \(Int(before.width)) to \(Int(after.width)))")
        }

        restore(window, to: original, pause: pause)
    }

    /// Puts the window back with the choreography most likely to be obeyed:
    /// position, size, position, since the original size is by definition one the
    /// window has already accepted.
    private static func restore(_ window: RawFrameWriting, to original: CGRect,
                                pause: () -> Void) {
        window.writeAXPosition(original.origin)
        window.writeAXSize(original.size)
        window.writeAXPosition(original.origin)
        pause()
    }
}
