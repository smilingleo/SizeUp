import CoreGraphics
import Foundation
import Geometry

/// A display's Spaces, as `SLSCopyManagedDisplaySpaces` reports them.
///
/// `spaces` is already in strip order (left to right), which is what
/// `neighbouringSpace` (Geometry) expects — no reordering happens here.
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
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let spaceDictionaries = display["Spaces"] as? [[String: Any]] ?? []
            let spaces = spaceDictionaries.compactMap(managedSpaceID)
            guard let currentDictionary = display["Current Space"] as? [String: Any],
                  let current = managedSpaceID(currentDictionary)
            else { return nil }
            return SpaceLayout(displayIdentifier: identifier, spaces: spaces, current: current)
        }
    }

    private static func managedSpaceID(_ dictionary: [String: Any]) -> SpaceIdentifier? {
        guard let raw = dictionary["ManagedSpaceID"] as? Int else { return nil }
        return SpaceIdentifier(UInt64(raw))
    }

    public func spaces(of windowID: CGWindowID) -> [SpaceIdentifier] {
        guard let connectionID = sky.connectionID, let copy = sky.copySpacesForWindows else { return [] }
        // 0x7 selects all spaces a window occupies, per move.swift, which
        // used it for the before/after read that proved the move worked.
        let raw = copy(connectionID(), 0x7, [windowID] as CFArray) as? [Int] ?? []
        return raw.map { SpaceIdentifier(UInt64($0)) }
    }

    @discardableResult
    public func move(windowID: CGWindowID, to space: SpaceIdentifier) -> Bool {
        guard let connectionID = sky.connectionID, let move = sky.moveWindowsToManagedSpace else { return false }
        move(connectionID(), [windowID] as CFArray, space.rawValue)
        return true
    }

    @discardableResult
    public func activate(_ space: SpaceIdentifier, onDisplay display: String) -> Bool {
        guard let connectionID = sky.connectionID, let setSpace = sky.managedDisplaySetCurrentSpace else {
            return false
        }
        setSpace(connectionID(), display as CFString, space.rawValue)
        return true
    }
}
