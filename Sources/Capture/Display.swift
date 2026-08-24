import CoreGraphics

/// Which display a point or a window frame belongs to.
///
/// Everything here is CoreGraphics-only (layering lint): the mouse is read
/// with a `CGEvent` from the combined session source and displays are matched
/// with `CGGetDisplaysWithPoint`, so `OverlayUI` can ask "which screen is the
/// cursor on" without this target ever importing AppKit.
///
/// Coordinates: CoreGraphics global space, top-left origin of the primary
/// display — the same space `SCDisplay` and `CGDisplayBounds` use. The
/// AppKit-frame variant converts at the boundary and is tested against
/// `WindowKit`'s conversion (see `CaptureTests`): two copies of the same
/// flip, which must agree.
public struct DisplayLocation: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let bounds: CGRect

    public init(id: CGDirectDisplayID, bounds: CGRect) {
        self.id = id
        self.bounds = bounds
    }
}

/// The seam `Display` lookups go through. Production implements it with
/// CoreGraphics; tests implement it with a synthetic display table, because
/// the real `CGGetDisplaysWithPoint` cannot be pointed at a display that does
/// not exist.
public protocol DisplayLookup: Sendable {
    func display(containing point: CGPoint) -> DisplayLocation?
    var mainDisplay: DisplayLocation { get }
}

public enum Display {
    /// The display the cursor is on, falling back to the main display when
    /// the event source is unavailable (a session with no mouse, e.g. a
    /// headless automation context). `CGEvent(source:)` is failable in Swift,
    /// hence the optional dance rather than a force-unwrap.
    /// Pure: match a CoreGraphics point to a display, falling back to the main
    /// display when it is on none. Separated from the real-mouse reader so the
    /// matching/fallback logic is testable against a synthetic table.
    public static func resolve(_ point: CGPoint, lookup: DisplayLookup) -> DisplayLocation {
        lookup.display(containing: point) ?? lookup.mainDisplay
    }

    public static func display(containingCursor lookup: DisplayLookup = CGDisplayLookup()) -> DisplayLocation {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let event = CGEvent(source: source)
        else { return lookup.mainDisplay }
        return resolve(event.location, lookup: lookup)
    }

    /// The display whose frame a window (AppKit coordinates, bottom-left
    /// origin) sits on, matched by frame center. Center rather than origin
    /// because a window can overhang an edge; the conversion mirrors
    /// `WindowKit.Coordinates` and is tested against it.
    public static func display(
        forAppkitFrame frame: CGRect,
        lookup: DisplayLookup = CGDisplayLookup()
    ) -> DisplayLocation {
        let main = lookup.mainDisplay
        let center = CGPoint(
            x: frame.midX,
            y: main.bounds.height - frame.midY
        )
        return resolve(center, lookup: lookup)
    }
}

/// The CoreGraphics-backed `DisplayLookup`.
public struct CGDisplayLookup: DisplayLookup {
    public init() {}

    public var mainDisplay: DisplayLocation {
        let id = CGMainDisplayID()
        return DisplayLocation(id: id, bounds: CGDisplayBounds(id))
    }

    public func display(containing point: CGPoint) -> DisplayLocation? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else {
            return nil
        }
        return DisplayLocation(id: id, bounds: CGDisplayBounds(id))
    }
}
