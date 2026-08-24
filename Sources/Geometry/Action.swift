public enum Edge: Sendable, Equatable, CaseIterable {
    case left, right, top, bottom
}

public enum Corner: Sendable, Equatable, CaseIterable {
    case upperLeft, upperRight, lowerLeft, lowerRight
}

public enum Direction: Sendable, Equatable {
    case next, previous, above, below
}

public enum Action: Sendable, Equatable {
    case half(Edge)
    case quarter(Corner)
    case center
    case fullScreen
    case snapBack
    case display(Direction)
    case space(Direction)
    // The capture side of the merge (ClipShot). These are routing identifiers
    // only: they are never frame math, so `isPlacement` is false for them, and
    // they do not participate in the size cycle. `ActionRouter.perform` and
    // `FrameMath` must both refuse them — a capture action has no window frame
    // to apply — which is exactly why the exhaustive switches carry explicit
    // no-op arms for them rather than a `default:` that would swallow a future
    // mistake.
    case captureScreenshot
    case startRecording

    /// True when repeated presses should advance through the fraction list.
    /// Only halves cycle: a cycling quarter varies on two axes and its
    /// landing position stops being predictable.
    public var cycles: Bool {
        if case .half = self { return true }
        return false
    }

    /// Whether this action describes a layout that can be recomputed on a
    /// different display and produce the same visual result.
    ///
    /// Used when moving a window between displays: a window still sitting
    /// where we tiled it gets its action recomputed on the destination, which
    /// tiles exactly, rather than scaled proportionally, which can leave a
    /// one-point seam. `snapBack` restores a remembered frame and the moves
    /// describe a transition, so neither can be recomputed.
    public var isPlacement: Bool {
        switch self {
        case .half, .quarter, .center, .fullScreen: return true
        // Snap back, the moves, and the capture actions all leave the frame
        // untouched by `targetFrame`; App dispatches capture actions to the
        // capture session before the router is ever asked.
        case .snapBack, .display, .space, .captureScreenshot,
             .startRecording: return false
        }
    }

    /// True for the capture actions. `App` routes them to the capture session
    /// (region overlay / recording) rather than the window router, which has no
    /// frame math for them.
    public var isCapture: Bool {
        switch self {
        case .captureScreenshot, .startRecording: return true
        case .half, .quarter, .center, .fullScreen, .snapBack, .display, .space:
            return false
        }
    }
}
