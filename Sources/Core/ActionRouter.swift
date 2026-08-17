import CoreGraphics
import Geometry
import WindowKit

/// Turns an `Action` into a moved window.
@MainActor
public struct ActionRouter {
    private let screens: ScreenProviding
    private let windows: WindowProviding
    private let store: WindowStateStore
    private let gaps: Gaps
    private let spans: [Span]
    private let skipList: Set<String>
    private let spaces: SpaceControlling?
    private let followsWindowToSpace: Bool

    public init(
        screens: ScreenProviding,
        windows: WindowProviding,
        store: WindowStateStore,
        gaps: Gaps = .zero,
        spans: [Span] = [.half],
        skipList: Set<String> = [],
        spaces: SpaceControlling? = nil,
        followsWindowToSpace: Bool = true
    ) {
        self.screens = screens
        self.windows = windows
        self.store = store
        self.gaps = gaps
        self.spans = spans.isEmpty ? [.half] : spans
        self.skipList = skipList
        self.spaces = spaces
        self.followsWindowToSpace = followsWindowToSpace
    }

    public func perform(_ action: Action) {
        guard let window = windows.focusedWindow() else { return }
        if let bundle = window.bundleIdentifier, skipList.contains(bundle) { return }
        // A Space move does not use `current`, so this guard makes it require a
        // readable frame it has no need for. Kept deliberately: a focused window
        // whose frame cannot be read is one Accessibility is failing on generally,
        // and one precondition for every action is easier to reason about than a
        // per-action set. Recorded in the deferred findings rather than left as a
        // surprise.
        guard let current = window.frame() else { return }

        switch action {
        case .snapBack:
            guard let restore = store.snapBackFrame(for: window.key) else { return }
            let target = clampToVisibleScreen(restore, current: current)
            guard let achieved = window.setFrame(target) else { return }
            store.record(key: window.key, action: .snapBack,
                         achievedFrame: achieved, previousFrame: current)

        case .display(let direction):
            guard let source = screen(containing: current),
                  let destination = neighbouringScreen(
                      from: source, in: screens.screens, direction: direction
                  )
            else { return }

            let placement = retiled(
                current, from: source, to: destination,
                key: window.key, direction: direction
            )
            guard let achieved = window.setFrame(placement.frame) else { return }
            store.record(key: window.key, action: placement.action,
                         achievedFrame: achieved, previousFrame: current,
                         step: placement.step)

        // A space move must not record a placement or advance the size
        // cycle: the window's frame does not change, so recording one would
        // corrupt Snap Back and the cycle position. Every step below returns
        // early on failure, so a machine without the private API (or a
        // window with no derivable `CGWindowID`) does nothing rather than
        // crash.
        case .space(let direction):
            guard let spaces, spaces.isAvailable,
                  let windowID = window.windowID,
                  let layout = spaces.layout(containing: windowID),
                  let destination = neighbouringSpace(
                      from: layout.current, in: layout.spaces, direction: direction
                  ),
                  spaces.move(windowID: windowID, to: destination)
            else { return }
            // Following only happens after a successful move: following to a
            // Space the window did not reach would leave the user staring at
            // an empty Space.
            if followsWindowToSpace {
                _ = spaces.activate(destination, onDisplay: layout.display)
            }

        // Spelled out rather than `default:` so that a future `Action` case
        // fails to compile instead of silently being treated as a placement.
        case .half, .quarter, .center, .fullScreen:
            guard let screen = screen(containing: current) else { return }
            let step = store.cycleStep(for: window.key, action: action, currentFrame: current)
            let span = spans[step % spans.count]
            guard let target = targetFrame(
                for: action, on: screen, gaps: gaps, current: current, span: span
            ) else { return }
            guard let achieved = window.setFrame(target) else { return }
            store.record(key: window.key, action: action,
                         achievedFrame: achieved, previousFrame: current)
        }
    }

    /// If `frame` is not meaningfully reachable on any current screen —
    /// the display it was stored against has since been disconnected, or a
    /// resolution change shifted it so only a sliver still overlaps —
    /// center it into the `visibleFrame` of the screen the window is
    /// currently on, so Snap Back never strands the window somewhere the
    /// user cannot get a hand on it.
    private func clampToVisibleScreen(_ frame: CGRect, current: CGRect) -> CGRect {
        let all = screens.screens
        let reachable = all.contains { isReachable(frame, on: $0.visibleFrame) }
        guard !reachable, let screen = screen(containing: current) else { return frame }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        let x = max(visible.minX, (visible.midX - size.width / 2).rounded(.down))
        let y = max(visible.minY, (visible.midY - size.height / 2).rounded(.down))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// A frame counts as reachable on a screen only if at least half its
    /// area lands inside that screen's `visibleFrame`. A bare `overlap > 0`
    /// check would pass for a sliver of overlap — exactly the
    /// resolution-change case this clamp exists to catch — and apply the
    /// stored frame unchanged, leaving the window effectively unreachable.
    private func isReachable(_ frame: CGRect, on visible: CGRect) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        return overlap(frame, visible) / area >= 0.5
    }

    /// The display holding the largest part of `frame`, falling back to the
    /// primary display when the window overlaps none of them.
    private func screen(containing frame: CGRect) -> ScreenInfo? {
        let all = screens.screens
        guard !all.isEmpty else { return nil }
        let best = all.max { a, b in
            overlap(frame, a.frame) < overlap(frame, b.frame)
        }
        if let best, overlap(frame, best.frame) > 0 { return best }
        return all.first
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Where a window should land on `destination`, and what to record for it.
    ///
    /// A window still sitting exactly where we tiled it has its action
    /// recomputed on the destination display, which tiles exactly. Anything
    /// else — never tiled by us, or moved by the user since — is mapped
    /// proportionally, which is approximate but never wrong about intent.
    ///
    /// The recorded step is preserved rather than advanced: moving a window to
    /// another display is not a repeat press, and must not resize it.
    private func retiled(
        _ current: CGRect,
        from source: ScreenInfo,
        to destination: ScreenInfo,
        key: WindowKey,
        direction: Direction
    ) -> (frame: CGRect, action: Action, step: Int) {
        // `isPlacement` is belt-and-braces: `targetFrame` already returns nil
        // for every non-placement action, so the `let exact` binding below
        // would fall through anyway. It is kept because it states the intent at
        // the point of the decision, and because it keeps this correct if
        // `targetFrame` ever grows a case for one of those actions.
        if let held = store.retainedPlacement(for: key, currentFrame: current),
           held.action.isPlacement,
           let exact = targetFrame(
               for: held.action, on: destination, gaps: gaps,
               current: current, span: spans[held.step % spans.count]
           ) {
            return (exact, held.action, held.step)
        }
        // `.display(direction)` is a placeholder meaning "we moved this, but we
        // do not know its layout". Because it is not a placement action, the
        // next display move maps proportionally again rather than trusting a
        // layout we never established. The real direction is recorded rather
        // than a hardcoded `.next` so the stored state is not a lie.
        let mapped = proportionalFrame(current, from: source, to: destination)
        return (mapped, .display(direction), 0)
    }
}
