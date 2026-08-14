import CoreGraphics
import Geometry
import WindowKit

/// Remembers what was done to each window, so repeated presses can cycle and
/// Snap Back can restore the user's original frame.
///
/// Bounded by an LRU policy: long sessions touch many windows and this must
/// not grow without limit.
@MainActor
public final class WindowStateStore {
    private struct State {
        var lastAction: Action
        var appliedFrame: CGRect
        var originalFrame: CGRect
        var step: Int = 0

        /// The step a repeat press should use. The router wraps this against
        /// the length of its span list.
        var cycleStepAdvanced: Int { step + 1 }
    }

    private var states: [WindowKey: State] = [:]
    private var recency: [WindowKey] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { states.count }

    /// Which position in the span list the next placement should use.
    ///
    /// Returns a non-zero step only when the same cycling action is repeated
    /// and the window still sits exactly where it was last placed.
    public func cycleStep(for key: WindowKey, action: Action, currentFrame: CGRect) -> Int {
        let state = states[key]
        guard action.cycles,
              state?.lastAction == action,
              isOurs(state, comparedTo: currentFrame)
        else { return 0 }

        touch(key)
        return state!.cycleStepAdvanced
    }

    /// Records the outcome of a placement.
    ///
    /// - Parameters:
    ///   - achievedFrame: What the window actually ended up as, which may
    ///     differ from the request when the app enforces a minimum size.
    ///   - previousFrame: Where the window was immediately before. It becomes
    ///     the Snap Back target only when the window was not already under our
    ///     control, so a chain of actions still undoes to the user's original.
    public func record(key: WindowKey, action: Action, achievedFrame: CGRect, previousFrame: CGRect) {
        let existing = states[key]
        let wasOurs = isOurs(existing, comparedTo: previousFrame)
        let original = wasOurs ? (existing?.originalFrame ?? previousFrame) : previousFrame

        var state = State(lastAction: action, appliedFrame: achievedFrame, originalFrame: original)
        if let existing, existing.lastAction == action, wasOurs {
            state.step = existing.cycleStepAdvanced
        }
        states[key] = state
        touch(key)
        evictIfNeeded()
    }

    public func snapBackFrame(for key: WindowKey) -> CGRect? {
        guard let state = states[key] else { return nil }
        touch(key)
        return state.originalFrame
    }

    /// Whether `frame` still matches where we last left this window, i.e.
    /// whether the chain of our own actions is unbroken. Shared by
    /// `cycleStep` (which additionally requires the same repeated action) and
    /// `record` (which does not: any of our own actions keeps the chain
    /// alive for Snap Back purposes), so the two can never silently diverge
    /// on what "our chain" means at the frame level.
    private func isOurs(_ state: State?, comparedTo frame: CGRect) -> Bool {
        guard let state else { return false }
        return approximatelyEqual(state.appliedFrame, frame)
    }

    private func touch(_ key: WindowKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while states.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            states.removeValue(forKey: oldest)
        }
    }
}
