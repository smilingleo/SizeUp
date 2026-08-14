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

    public init(
        screens: ScreenProviding,
        windows: WindowProviding,
        store: WindowStateStore,
        gaps: Gaps = .zero,
        spans: [Span] = [.half],
        skipList: Set<String> = []
    ) {
        self.screens = screens
        self.windows = windows
        self.store = store
        self.gaps = gaps
        self.spans = spans.isEmpty ? [.half] : spans
        self.skipList = skipList
    }

    public func perform(_ action: Action) {
        guard let window = windows.focusedWindow() else { return }
        if let bundle = window.bundleIdentifier, skipList.contains(bundle) { return }
        guard let current = window.frame() else { return }

        switch action {
        case .snapBack:
            guard let restore = store.snapBackFrame(for: window.key) else { return }
            let target = clampToVisibleScreen(restore, current: current)
            guard let achieved = window.setFrame(target) else { return }
            store.record(key: window.key, action: .snapBack,
                         achievedFrame: achieved, previousFrame: current)

        case .display, .space:
            // M2 and M4.
            return

        default:
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

    /// If `frame` has no positive overlap with any current screen's
    /// `visibleFrame` — the display it was stored against has since been
    /// disconnected, or its resolution changed — center it into the
    /// `visibleFrame` of the screen the window is currently on, so Snap Back
    /// never strands the window somewhere unreachable.
    private func clampToVisibleScreen(_ frame: CGRect, current: CGRect) -> CGRect {
        let all = screens.screens
        let onAnyScreen = all.contains { overlap(frame, $0.visibleFrame) > 0 }
        guard !onAnyScreen, let screen = screen(containing: current) else { return frame }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(
            x: (visible.midX - size.width / 2).rounded(.down),
            y: (visible.midY - size.height / 2).rounded(.down),
            width: size.width,
            height: size.height
        )
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
}
