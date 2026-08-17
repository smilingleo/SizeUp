import Geometry

/// The seam `ActionRouter` uses to move a window between macOS Spaces.
///
/// `Core` must not import Foundation, so it cannot see `SpaceKit` (the
/// private-API wrapper that implements this for real) directly — the same
/// reason `ScreenProviding`/`WindowProviding` exist rather than a direct
/// dependency. `App` injects `SpaceService` as this protocol; tests inject a
/// fake.
public protocol SpaceControlling: Sendable {
    /// `false` if any private symbol the implementation needs is missing, so
    /// a Spaces shortcut can register and simply do nothing on a machine (or
    /// a future macOS) where the private API is unavailable, rather than
    /// crash.
    var isAvailable: Bool { get }

    /// The Spaces on the display currently holding `windowID`, in strip
    /// order, and which one holds it now. `nil` if the window cannot be
    /// located — closed since focus was captured, or the private API is
    /// unavailable.
    func layout(containing windowID: UInt32)
        -> (spaces: [SpaceIdentifier], current: SpaceIdentifier, display: String)?

    /// Moves the window to `space`. `false` on any failure.
    func move(windowID: UInt32, to space: SpaceIdentifier) -> Bool

    /// Switches the active Space on `display` to `space`. `false` on any
    /// failure.
    func activate(_ space: SpaceIdentifier, onDisplay display: String) -> Bool
}
