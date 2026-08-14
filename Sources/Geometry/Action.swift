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
        case .snapBack, .display, .space: return false
        }
    }
}
