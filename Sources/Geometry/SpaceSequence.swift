/// A macOS Space's `ManagedSpaceID`, distinct from a window ID or a display
/// identifier — this milestone juggles three different opaque integers and
/// they are easy to confuse if they are all bare `UInt64`s.
public struct SpaceIdentifier: Hashable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// The space one step from `current` in strip order, wrapping at both ends.
///
/// `spaces` is taken in the order given — the order `SLSCopyManagedDisplaySpaces`
/// reports a display's Spaces, which is already left-to-right strip order, so
/// unlike `neighbouringScreen` there is no spatial sort to do here.
///
/// Returns `nil` when there is nowhere to go: fewer than two spaces, or a
/// `current` that is not among `spaces`. Wrapping is required: SizeUp wraps,
/// and a non-wrapping version would silently do nothing at either end of the
/// strip, which reads as broken rather than as "no more spaces".
///
/// `.above`/`.below` always return `nil`. macOS has arranged Spaces in a
/// single horizontal strip per display since Lion; there is no vertical
/// neighbour for either direction to reach, so guessing one (say, above →
/// previous) would be behaviour invented rather than reproduced, and the
/// failure mode is a window landing on a Space the user did not ask for.
public func neighbouringSpace(
    from current: SpaceIdentifier,
    in spaces: [SpaceIdentifier],
    direction: Direction
) -> SpaceIdentifier? {
    let step: Int
    switch direction {
    case .next: step = 1
    case .previous: step = -1
    case .above, .below: return nil
    }

    guard spaces.count > 1, let index = spaces.firstIndex(of: current) else {
        return nil
    }
    let count = spaces.count
    return spaces[((index + step) % count + count) % count]
}
