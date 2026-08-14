import CoreGraphics

/// The display one step from `current` in spatial order, wrapping at both ends.
///
/// Returns `nil` when there is nowhere to go: fewer than two displays, a
/// `current` that is not among `screens`, or a direction that does not apply
/// to displays. `.above`/`.below` are reserved for Spaces (M4) and must never
/// be silently reinterpreted as `.next`/`.previous` — a window landing on the
/// wrong display is worse than a shortcut doing nothing.
public func neighbouringScreen(
    from current: ScreenInfo,
    in screens: [ScreenInfo],
    direction: Direction
) -> ScreenInfo? {
    let step: Int
    switch direction {
    case .next: step = 1
    case .previous: step = -1
    case .above, .below: return nil
    }

    let ordered = spatiallyOrdered(screens)
    guard ordered.count > 1, let index = ordered.firstIndex(where: { $0.id == current.id }) else {
        return nil
    }
    let count = ordered.count
    return ordered[((index + step) % count + count) % count]
}
