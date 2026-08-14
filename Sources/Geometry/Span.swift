import CoreGraphics

/// How much of an axis a window covers, expressed as columns of a grid.
///
/// A left half is `Span(occupied: 1, of: 2)`; a left two-thirds is
/// `Span(occupied: 2, of: 3)`. Expressing it this way — rather than as a bare
/// fraction — is what makes gap arithmetic exact: an N-column layout has
/// exactly N-1 inner gaps, so both sides of a split agree on how much space
/// the gaps consume. A bare fraction cannot express that agreement, and
/// asymmetric splits then leave a seam.
public struct Span: Sendable, Equatable {
    public let occupied: Int
    public let columns: Int

    public init(occupied: Int, of columns: Int) {
        precondition(columns > 0, "a layout needs at least one column")
        precondition(occupied > 0 && occupied <= columns, "occupied must be within the layout")
        self.occupied = occupied
        self.columns = columns
    }

    public static let half = Span(occupied: 1, of: 2)

    /// The span covering the rest of the axis.
    public var complement: Span? {
        occupied < columns ? Span(occupied: columns - occupied, of: columns) : nil
    }
}
