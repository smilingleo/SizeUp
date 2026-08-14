import CoreGraphics

/// Computes where a window should go.
///
/// Everything is in Cocoa coordinates: origin bottom-left, +Y upward.
/// All math derives from `screen.visibleFrame`, which already excludes the
/// menu bar and Dock.
///
/// - Parameters:
///   - action: What to do. Only `.half`, `.quarter`, `.center`, and
///     `.fullScreen` are handled here. `.snapBack`, `.display`, and `.space`
///     are not single-screen frame math and are dispatched by the caller;
///     this function returns `nil` for them.
///   - current: The window's present frame. Required by `.center`, which
///     preserves the window's size, matching SizeUp.
///   - fraction: The window's share of the usable extent along the axis the
///     action names. `0.5` for a half, `1.0/3.0` for a third.
/// - Returns: The target frame, or `nil` if the action is not handled here
///   or a required input is missing.
public func targetFrame(
    for action: Action,
    on screen: ScreenInfo,
    gaps: Gaps = .zero,
    current: CGRect? = nil,
    fraction: CGFloat = 0.5
) -> CGRect? {
    let usable = screen.visibleFrame.insetBy(dx: gaps.outer, dy: gaps.outer)
    guard usable.width > 0, usable.height > 0 else { return nil }

    switch action {
    case .fullScreen:
        return usable

    case .center:
        guard let current else { return nil }
        let size = CGSize(
            width: min(current.width, usable.width),
            height: min(current.height, usable.height)
        )
        return CGRect(
            x: (usable.midX - size.width / 2).rounded(.down),
            y: (usable.midY - size.height / 2).rounded(.down),
            width: size.width,
            height: size.height
        )

    case .half(let edge):
        switch edge {
        case .left:
            let w = leadingExtent(usable.width, fraction, gaps.inner)
            return CGRect(x: usable.minX, y: usable.minY, width: w, height: usable.height)
        case .right:
            let w = trailingExtent(usable.width, fraction, gaps.inner)
            return CGRect(x: usable.maxX - w, y: usable.minY, width: w, height: usable.height)
        case .bottom:
            let h = leadingExtent(usable.height, fraction, gaps.inner)
            return CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: h)
        case .top:
            let h = trailingExtent(usable.height, fraction, gaps.inner)
            return CGRect(x: usable.minX, y: usable.maxY - h, width: usable.width, height: h)
        }

    case .quarter(let corner):
        // Quarters never cycle, so both axes are always split in half.
        let leftW = leadingExtent(usable.width, 0.5, gaps.inner)
        let rightW = trailingExtent(usable.width, 0.5, gaps.inner)
        let bottomH = leadingExtent(usable.height, 0.5, gaps.inner)
        let topH = trailingExtent(usable.height, 0.5, gaps.inner)
        switch corner {
        case .upperLeft:
            return CGRect(x: usable.minX, y: usable.maxY - topH, width: leftW, height: topH)
        case .upperRight:
            return CGRect(x: usable.maxX - rightW, y: usable.maxY - topH, width: rightW, height: topH)
        case .lowerLeft:
            return CGRect(x: usable.minX, y: usable.minY, width: leftW, height: bottomH)
        case .lowerRight:
            return CGRect(x: usable.maxX - rightW, y: usable.minY, width: rightW, height: bottomH)
        }

    case .snapBack, .display, .space:
        return nil
    }
}

/// Number of inner gaps a layout of `1/fraction` columns places *between*
/// windows. Halves and two-thirds have one internal boundary; thirds have two.
private func boundaryCount(_ fraction: CGFloat) -> CGFloat {
    guard fraction > 0 else { return 0 }
    return max(0, (1 / fraction).rounded(.up) - 1)
}

/// Extent of a window anchored to the low edge of the axis.
private func leadingExtent(_ total: CGFloat, _ fraction: CGFloat, _ inner: CGFloat) -> CGFloat {
    let available = total - boundaryCount(fraction) * inner
    return max(0, (available * fraction).rounded(.down))
}

/// Extent of a window anchored to the high edge of the axis.
///
/// Defined as the complement of the leading window that would sit beside it,
/// which guarantees the pair tiles exactly with no seam and no overlap on
/// odd-sized displays.
private func trailingExtent(_ total: CGFloat, _ fraction: CGFloat, _ inner: CGFloat) -> CGFloat {
    let available = total - boundaryCount(fraction) * inner
    let complement = (available * (1 - fraction)).rounded(.down)
    return max(0, available - complement)
}
