import CoreGraphics
import Foundation
import Geometry

/// A display's Spaces, as `SLSCopyManagedDisplaySpaces` reports them.
///
/// `spaces` is already in strip order (left to right), which is what
/// `neighbouringSpace` (Geometry) expects — no reordering happens here.
/// A display's ordinary Spaces, in strip order, and which one it is showing.
///
/// `spaces` excludes full-screen applications' Spaces, so `current` is not
/// necessarily among them: when the display is showing a full-screen app, no
/// neighbour can be computed and the Spaces shortcuts correctly do nothing
/// rather than moving a window out of a full-screen Space to somewhere the user
/// cannot see it happen.
public struct SpaceLayout: Equatable, Sendable {
    public let displayIdentifier: String
    public let spaces: [SpaceIdentifier]
    public let current: SpaceIdentifier

    public init(displayIdentifier: String, spaces: [SpaceIdentifier], current: SpaceIdentifier) {
        self.displayIdentifier = displayIdentifier
        self.spaces = spaces
        self.current = current
    }
}

/// The private-API wrapper for macOS Spaces: the only type in the project
/// that reads or writes Spaces state. `Core` (Task 3) sees this only through
/// the `SpaceControlling` seam, never directly, so a change here cannot
/// ripple past this target's boundary.
public final class SpaceService: Sendable {
    private let sky: SkyLight

    public init() {
        self.sky = .shared
    }

    /// Test-only seam: reached from `SpaceKitTests` via `@testable import`
    /// to exercise the degradation path with a `SkyLight` built from a nil
    /// `dlopen` handle, without touching the real private API.
    init(sky: SkyLight) {
        self.sky = sky
    }

    /// False if any symbol every method below needs failed to resolve. Each
    /// method already checks its own symbols and fails safely on its own;
    /// this lets a caller decide once whether to register the Spaces
    /// shortcuts at all, per the M5 plan's "every entry point degrades"
    /// requirement.
    public var isAvailable: Bool {
        sky.connectionID != nil
            && sky.copyManagedDisplaySpaces != nil
            && sky.moveWindowsToManagedSpace != nil
            && sky.copySpacesForWindows != nil
            && sky.managedDisplaySetCurrentSpace != nil
    }

    public func displaySpaces() -> [SpaceLayout] {
        guard let connectionID = sky.connectionID, let copy = sky.copyManagedDisplaySpaces else { return [] }
        let raw = copy(connectionID()) as? [[String: Any]] ?? []
        return Self.parse(raw)
    }

    /// A pure function over the plist-shaped array `SLSCopyManagedDisplaySpaces`
    /// returns, split out of `displaySpaces()` so it is reachable from a test
    /// with a fixture and no private API. Every level is optional: a shape
    /// change on a future macOS must yield an empty or partial result rather
    /// than trap, per the M5 plan's "do not make it three [launch-killing
    /// traps]".
    static func parse(_ displays: [[String: Any]]) -> [SpaceLayout] {
        displays.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String,
                  isUsableDisplayIdentifier(identifier)
            else { return nil }
            let spaceDictionaries = display["Spaces"] as? [[String: Any]] ?? []
            // Only ordinary user Spaces are targets. A full-screen application
            // occupies its own Space of `type` 4, and macOS puts it IN THE STRIP
            // between the user's Spaces — measured on this machine, making
            // TextEdit full-screen turned [1, 3] into [1, 398(type 4), 3]. So
            // "next Space" would have moved the window INTO the full-screen app's
            // Space and, by default, followed it there: the window becomes
            // invisible behind another app's full-screen window, which is the
            // worst outcome this feature has, and it happens on any Mac with a
            // full-screen app open.
            let spaces = spaceDictionaries.filter(isUserSpace).compactMap(managedSpaceID)
            guard let currentDictionary = display["Current Space"] as? [String: Any],
                  let current = managedSpaceID(currentDictionary)
            else { return nil }
            return SpaceLayout(displayIdentifier: identifier, spaces: spaces, current: current)
        }
    }

    /// `SLSManagedDisplaySetCurrentSpace` ABORTS THE PROCESS on an identifier it
    /// cannot parse — measured: "garbage" and "" both die with
    /// `Assertion failed: (uuid_parse(...) == 0), function parse_uuid_string,
    /// file CGSSpace.c`, exit 134. It is a C assertion inside the window server
    /// framework, so it cannot be caught.
    ///
    /// This is the FOURTH launch-killing conversion of this shape in this project,
    /// and it was missed twice: the review that found the integer ones described a
    /// class of defect, and the fix hardened only the two integers it named while
    /// walking past a string from the very same dictionary. Hence: everything taken
    /// out of this dictionary is validated, not just the numbers.
    ///
    /// "Main" is accepted because it is a real value the framework handles — also
    /// measured, alongside a well-formed UUID naming no attached display, which is
    /// likewise safe.
    private static func isUsableDisplayIdentifier(_ identifier: String) -> Bool {
        identifier == "Main" || UUID(uuidString: identifier) != nil
    }

    /// `type` 0 is an ordinary Space. 4 is a full-screen application's own
    /// Space; other values exist for other system-managed Spaces. Anything that
    /// is not plainly 0 is excluded, rather than excluding a known list of bad
    /// values — a `type` this code has never seen is far more likely to be
    /// another system-managed Space than a new kind of user one, and the cost of
    /// wrongly excluding is a shortcut that does nothing, against wrongly
    /// including which hides the user's window inside another app.
    private static func isUserSpace(_ dictionary: [String: Any]) -> Bool {
        (dictionary["type"] as? Int) == 0
    }

    private static func managedSpaceID(_ dictionary: [String: Any]) -> SpaceIdentifier? {
        guard let raw = dictionary["ManagedSpaceID"] as? Int else { return nil }
        return spaceIdentifier(raw)
    }

    /// `UInt64(_:)` traps on a negative value, and this parses data from a
    /// private API on a future OS. Two launch-killing traps have already shipped
    /// in this project from exactly this shape of conversion, in a file whose
    /// comment promised the input was validated — measured here too:
    /// `UInt64(-5)` aborts.
    private static func spaceIdentifier(_ raw: Int) -> SpaceIdentifier? {
        guard let value = UInt64(exactly: raw) else { return nil }
        return SpaceIdentifier(value)
    }

    /// Picks the display whose Space strip the window is actually on, and where in
    /// that strip it sits.
    ///
    /// Keyed on the window's own Space rather than on which display its frame
    /// overlaps. A window can sit on a Space that is not the one its display is
    /// currently showing, and moving it relative to the *visible* Space instead of
    /// its own would send it somewhere the user did not ask for.
    ///
    /// A window assigned to every Space (`Assign To: All Desktops`) occupies many,
    /// so the first display owning any of them wins; with such a window there is no
    /// better answer, and it is at least deterministic in `displaySpaces` order.
    ///
    /// Pure, and public, so it can be tested: this is the one piece of the Spaces
    /// logic that is neither trivial nor exercised by the private API, and it lived
    /// in the untested `App` target until a reviewer pointed out that its
    /// untestability was a placement choice rather than a fact.
    public static func locate(
        windowOn occupied: [SpaceIdentifier],
        in layouts: [SpaceLayout]
    ) -> (spaces: [SpaceIdentifier], current: SpaceIdentifier, display: String)? {
        // No early return for an empty `occupied`: the loop below already yields
        // nil, since no layout can contain a Space from an empty list. A guard was
        // written here first and removing it broke no test — because it could not.
        // The test that pins the empty case stays, as it describes the behaviour
        // rather than this line.
        for layout in layouts {
            guard let here = occupied.first(where: { layout.spaces.contains($0) }) else { continue }
            return (layout.spaces, here, layout.displayIdentifier)
        }
        return nil
    }

    public func spaces(of windowID: CGWindowID) -> [SpaceIdentifier] {
        guard let connectionID = sky.connectionID, let copy = sky.copySpacesForWindows else { return [] }
        // 0x7 selects all spaces a window occupies, per move.swift, which
        // used it for the before/after read that proved the move worked.
        let raw = copy(connectionID(), 0x7, [windowID] as CFArray) as? [Int] ?? []
        return raw.compactMap(Self.spaceIdentifier)
    }

    /// Moves the window and **verifies** it, rather than reporting the success of
    /// having called a function.
    ///
    /// `SLSMoveWindowsToManagedSpace` returns `Void`, so calling it tells us
    /// nothing. Returning `true` regardless would make the caller's "only follow
    /// the window if the move succeeded" rule meaningless, and following a window
    /// that did not move leaves the user staring at a Space it is not on —
    /// exactly the "window has vanished" outcome that rule exists to prevent.
    ///
    /// The read-back is cheap enough to do synchronously in a hotkey handler:
    /// measured on this machine, the new Space is already visible to the first read,
    /// and a warm read of the Space layout costs 0.05–0.12ms. The FIRST such call in
    /// a process costs about 40ms, presumably connecting to the window server; that
    /// happens once, at the first Spaces shortcut of the session.
    ///
    /// An earlier version of this comment claimed "three to six milliseconds" per
    /// read. That figure was never reproducible and is corrected here rather than
    /// left to be believed.
    ///
    /// It is still a race — the window server is another process — so the read is
    /// retried a bounded number of times. A single read that lost the race would
    /// report failure for a move that worked, and the caller would then decline to
    /// follow a window that had in fact gone: the user is left on the old Space
    /// with the window apparently vanished, which is the exact outcome the return
    /// value exists to prevent.
    @discardableResult
    public func move(windowID: CGWindowID, to space: SpaceIdentifier) -> Bool {
        guard let connectionID = sky.connectionID, let move = sky.moveWindowsToManagedSpace else { return false }
        move(connectionID(), [windowID] as CFArray, space.rawValue)
        // `contains` rather than equality: a window assigned to every Space
        // legitimately reports several, and that is not a failure.
        return confirm { spaces(of: windowID).contains(space) }
    }

    /// Polls `condition` a bounded number of times.
    ///
    /// Bounded and short: this runs on the main thread inside a hotkey handler, so
    /// the ceiling matters more than the certainty. Roughly 50ms worst case, which
    /// is imperceptible, against a measured typical cost of one read.
    private func confirm(_ condition: () -> Bool) -> Bool {
        for attempt in 0..<10 {
            if condition() { return true }
            if attempt < 9 { usleep(5_000) }
        }
        return false
    }

    @discardableResult
    public func activate(_ space: SpaceIdentifier, onDisplay display: String) -> Bool {
        guard let connectionID = sky.connectionID, let setSpace = sky.managedDisplaySetCurrentSpace else {
            return false
        }
        setSpace(connectionID(), display as CFString, space.rawValue)
        // Verified by reading the display's current Space back, for the same
        // reason `move` does: `SLSManagedDisplaySetCurrentSpace` returns `Void`,
        // so reporting success for having called it says nothing. This is the
        // step whose silent failure IS the vanished-window outcome — the window
        // has moved and the user has not been taken to it — so it is the last
        // place to accept "I called a function" as an answer.
        return confirm {
            displaySpaces().first { $0.displayIdentifier == display }?.current == space
        }
    }
}
