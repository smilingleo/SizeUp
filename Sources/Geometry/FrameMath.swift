import CoreGraphics

/// Whether this rect is safe to hand to the Accessibility API.
///
/// A NaN or infinite frame is not merely wrong, it is unrecoverable: a
/// window placed at a non-finite position has nothing on screen left to
/// drag back. Such values are reachable in practice, because frames are
/// read from other processes and a hung application can report garbage.
///
/// A zero or negative size is rejected for the same reason, and this is not
/// hypothetical. A gap of 100 — a value the Settings window itself offers —
/// combined with a 12-column span, which the settings validator accepts,
/// produces a zero-HEIGHT bottom half on a 1080p display. That was measured,
/// after an earlier version of this comment claimed the configuration cap made
/// it unreachable; it only ever checked two columns.
extension CGRect {
    public var isSafeToApply: Bool {
        // `size.width`/`size.height` are the raw stored values. `rect.width`
        // would return the standardized (absolute) width and so would happily
        // accept a negative size.
        origin.x.isFinite && origin.y.isFinite
            && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
    }
}

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
///   - span: How much of the axis the window covers, as columns of a grid.
///     `Span.half` for a half, `Span(occupied: 1, of: 3)` for a third.
/// - Returns: The target frame, or `nil` if the action is not handled here
///   or a required input is missing.
public func targetFrame(
    for action: Action,
    on screen: ScreenInfo,
    gaps: Gaps = .zero,
    current: CGRect? = nil,
    span: Span = .half
) -> CGRect? {
    let usable = screen.visibleFrame.insetBy(dx: gaps.outer, dy: gaps.outer)
    guard usable.width > 0, usable.height > 0 else { return nil }

    // Computed once and validated once, rather than trusting each arm. A large
    // inner gap spread over many columns can consume the whole axis and leave an
    // extent of zero, and a zero-size window has nothing left to grab. Refusing
    // here means the caller does nothing at all, which is the right outcome:
    // there is no sensible window to draw for that configuration.
    guard let result = placement(for: action, in: usable, gaps: gaps, current: current, span: span),
        result.width > 0, result.height > 0
    else { return nil }
    return result
}

private func placement(
    for action: Action,
    in usable: CGRect,
    gaps: Gaps,
    current: CGRect?,
    span: Span
) -> CGRect? {
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
            let w = leadingExtent(usable.width, span, gaps.inner)
            return CGRect(x: usable.minX, y: usable.minY, width: w, height: usable.height)
        case .right:
            let w = trailingExtent(usable.width, span, gaps.inner)
            return CGRect(x: usable.maxX - w, y: usable.minY, width: w, height: usable.height)
        case .bottom:
            let h = leadingExtent(usable.height, span, gaps.inner)
            return CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: h)
        case .top:
            let h = trailingExtent(usable.height, span, gaps.inner)
            return CGRect(x: usable.minX, y: usable.maxY - h, width: usable.width, height: h)
        }

    case .quarter(let corner):
        // Quarters never cycle, so both axes are always split in half.
        let leftW = leadingExtent(usable.width, .half, gaps.inner)
        let rightW = trailingExtent(usable.width, .half, gaps.inner)
        let bottomH = leadingExtent(usable.height, .half, gaps.inner)
        let topH = trailingExtent(usable.height, .half, gaps.inner)
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

    // Capture actions are not frame math. They appear here only because the
    // switch is exhaustive; App routes them to the capture session and never
    // calls `targetFrame` with one.
    case .captureScreenshot, .startRecording:
        return nil
    }
}

/// Extent of a window anchored to the low edge of the axis.
///
/// An N-column layout spends `(N-1) * inner` on gaps; what remains is split
/// N ways. A window covering k columns also absorbs the `k-1` gaps that fall
/// inside it.
private func leadingExtent(_ total: CGFloat, _ span: Span, _ inner: CGFloat) -> CGFloat {
    let columns = CGFloat(span.columns)
    let occupied = CGFloat(span.occupied)
    let available = total - (columns - 1) * inner
    guard available > 0 else { return 0 }
    let column = (available * occupied / columns).rounded(.down)
    return max(0, column + (occupied - 1) * inner)
}

/// Extent of a window anchored to the high edge of the axis.
///
/// Defined as whatever the complementary leading window leaves behind, which
/// guarantees the pair tiles the axis exactly — no seam, no overlap — for any
/// span and any gap, including odd-sized displays.
private func trailingExtent(_ total: CGFloat, _ span: Span, _ inner: CGFloat) -> CGFloat {
    guard let complement = span.complement else { return total }
    return max(0, total - inner - leadingExtent(total, complement, inner))
}

/// Frames are compared with a tolerance because an application may settle
/// at a frame a fraction of a point away from what it was given, on a
/// later run-loop turn than our read-back. Exact equality would then make
/// us think the user had moved the window by hand.
public func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= tolerance
        && abs(a.minY - b.minY) <= tolerance
        && abs(a.maxX - b.maxX) <= tolerance
        && abs(a.maxY - b.maxY) <= tolerance
}
