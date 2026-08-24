import CoreGraphics
import Diagnostics
import Geometry

/// Finds out, by experiment, what a window will actually accept.
///
/// This exists because one window on one machine reached the end of what can be
/// deduced. Slack, asked to fill a 3360x1860 display, kept its 2056x1290 size
/// while Accessibility reported the size as settable, reported no error on the
/// write, reported the window as a standard non-full-screen window, and reported
/// the application as owning exactly one window. Every hypothesis that could be
/// checked by reading was checked, and each came back clean. What is left is to
/// ask the window a series of narrower questions and watch which one it refuses.
///
/// The trials are generated here, as arithmetic, so the interesting part is
/// testable: they bisect the two candidate walls independently. Height alone,
/// width alone, both together, and a size the window already has — because a
/// window that refuses even its current size is telling a different story from
/// one that refuses only growth.
///
/// Nothing here is a fix, and it is deliberately not on any user-facing path.
/// It is a way to turn "Slack does not resize" into a number.
public struct WindowProbe {
    public struct Trial: Equatable, Sendable {
        /// What the trial is asking, in words, for the log.
        public let question: String
        public let frame: CGRect

        public init(question: String, frame: CGRect) {
            self.question = question
            self.frame = frame
        }
    }

    /// The questions to ask a window sitting at `current` on `screen`.
    ///
    /// Ordered from least to most demanding, so the log reads as a bisection
    /// and the first refusal is the answer.
    public static func trials(for current: CGRect, on screen: ScreenInfo) -> [Trial] {
        let usable = screen.visibleFrame
        var trials: [Trial] = []

        // The control. A window that will not accept the size it already has is
        // not enforcing a limit, it is ignoring us, and every later trial would
        // be misread without this one.
        trials.append(Trial(question: "its own current size", frame: current))

        // Position only, size untouched: separates the two writes. The position
        // write has been the reliable one, and this confirms it in isolation.
        trials.append(Trial(
            question: "a move with no resize",
            frame: CGRect(origin: usable.origin, size: current.size)
        ))

        // Width alone, then height alone. Only one of the two dimensions was
        // ever suspicious — the height was pinned at another display's usable
        // height — and asking separately says which.
        trials.append(Trial(
            question: "full usable width, unchanged height",
            frame: CGRect(x: usable.minX, y: current.minY,
                          width: usable.width, height: current.height)
        ))
        trials.append(Trial(
            question: "full usable height, unchanged width",
            frame: CGRect(x: current.minX, y: usable.minY,
                          width: current.width, height: usable.height)
        ))

        // Bisect the height between what it has and what it refused. If there is
        // a hard ceiling rather than a flat refusal, it shows up as the point
        // where these stop being honoured.
        for fraction in [0.25, 0.5, 0.75] {
            let height = current.height + (usable.height - current.height) * fraction
            guard height > current.height + 1 else { continue }
            trials.append(Trial(
                question: "height \(Int(height.rounded())), \(Int(fraction * 100))% of the way",
                frame: CGRect(x: current.minX, y: usable.minY,
                              width: current.width, height: height)
            ))
        }

        // Shorter, with the width left alone. This is the trial that separates
        // "the height has a maximum" from "the height cannot change", and the
        // width has to stay put for it to mean anything: a narrow trial can be
        // refused for violating a minimum width instead, and then it answers
        // nothing. Three quarters of the current height, which is well clear of
        // any plausible minimum.
        trials.append(Trial(
            question: "shorter, unchanged width",
            frame: CGRect(x: current.minX, y: current.minY,
                          width: current.width,
                          height: (current.height * 0.75).rounded())
        ))

        // A smaller size, in both dimensions. Growth and shrinkage are not the
        // same request, and a window that shrinks but will not grow has a
        // maximum, not a general refusal.
        trials.append(Trial(
            question: "half its current size",
            frame: CGRect(x: current.minX, y: current.minY,
                          width: (current.width / 2).rounded(),
                          height: (current.height / 2).rounded())
        ))

        // And the thing that started it: the whole display.
        trials.append(Trial(question: "the whole usable display", frame: usable))

        return trials
    }

    /// Puts each question to the window and logs the answer, then puts the
    /// window back where it was found.
    ///
    /// The restore is not politeness. A probe that leaves the window halfway
    /// through a bisection makes the next probe's control trial meaningless.
    public static func run(on window: WindowHandle, screen: ScreenInfo) {
        let who = window.bundleIdentifier ?? "the focused window"
        guard let original = window.frame() else {
            Log.problem("probe: cannot read \(who)'s frame")
            return
        }
        Log.problem("probe: \(who) at \(Self.text(original))"
            + " on usable \(Self.text(screen.visibleFrame))")

        for trial in trials(for: original, on: screen) {
            let achieved = window.setFrame(trial.frame)
            let verdict: String
            if let achieved {
                let off = FrameApplier.offset(of: achieved, from: trial.frame)
                verdict = off <= 1 ? "took it" : "off by \(Int(off.rounded()))pt"
            } else {
                verdict = "unreadable"
            }
            Log.problem("probe: asked \(who) for \(trial.question)"
                + " \(Self.text(trial.frame)) — \(verdict),"
                + " got \(Self.text(achieved))")
        }

        window.setFrame(original)
        Log.problem("probe: \(who) restored to \(Self.text(original))")
    }

    private static func text(_ rect: CGRect?) -> String {
        guard let rect else { return "(unreadable)" }
        return "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}
