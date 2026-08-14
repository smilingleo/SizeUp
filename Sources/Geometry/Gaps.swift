import CoreGraphics

/// Spacing applied when placing windows.
///
/// `inner` is the space between two adjacent windows. `outer` is the space
/// between a window and the edge of the usable screen area.
public struct Gaps: Sendable, Equatable {
    public var inner: CGFloat
    public var outer: CGFloat

    public init(inner: CGFloat = 0, outer: CGFloat = 0) {
        self.inner = inner
        self.outer = outer
    }

    public static let zero = Gaps()
}
