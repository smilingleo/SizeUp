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
}
