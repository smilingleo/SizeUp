import CoreGraphics

/// Maps `frame` onto `destination` by preserving its position and size
/// *relative* to `source`, so a window a third of the way across a wide
/// display lands a third of the way across a narrow one.
///
/// Both displays are measured by `visibleFrame`, so the menu bar and Dock are
/// excluded on each — they differ per display, and a window mapped against
/// full `frame`s would slide under them.
///
/// Extents are floored and then clamped inside the destination: flooring keeps
/// the result deterministic for tests, and the clamp guarantees the window is
/// reachable even when rounding or an oversized source frame would otherwise
/// push it past an edge.
public func proportionalFrame(
    _ frame: CGRect,
    from source: ScreenInfo,
    to destination: ScreenInfo
) -> CGRect {
    let src = source.visibleFrame
    let dst = destination.visibleFrame
    guard src.width > 0, src.height > 0, dst.width > 0, dst.height > 0 else { return frame }

    let relativeX = (frame.minX - src.minX) / src.width
    let relativeY = (frame.minY - src.minY) / src.height
    let relativeWidth = frame.width / src.width
    let relativeHeight = frame.height / src.height

    let width = min((relativeWidth * dst.width).rounded(.down), dst.width)
    let height = min((relativeHeight * dst.height).rounded(.down), dst.height)
    let x = min(max((dst.minX + relativeX * dst.width).rounded(.down), dst.minX), dst.maxX - width)
    let y = min(max((dst.minY + relativeY * dst.height).rounded(.down), dst.minY), dst.maxY - height)

    return CGRect(x: x, y: y, width: width, height: height)
}
