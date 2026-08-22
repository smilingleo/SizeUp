import CoreGraphics
import ScreenCaptureKit

/// The displays and windows on screen, fetched in one call and looked up by
/// the IDs the rest of the app already uses.
///
/// This is the bridge between the two ID spaces the capture feature needs:
/// `SCDisplay`/`SCWindow` (ScreenCaptureKit) and `CGDirectDisplayID`/`CGWindowID`
/// (CoreGraphics). `NSWindow.windowNumber` and `SCWindow.windowID` are the
/// same number (probe-verified against a live window), and `SCWindow.windowID`
/// is also what `WindowKit`'s private `_AXUIElementGetWindow` bridge yields, so
/// one ID space serves exclusion, and no translation is needed.
///
/// `excludingDesktopWindows(false, onScreenWindowsOnly: true)` is deliberate:
/// the overlay must see the desktop and the Dock (it captures the whole
/// display), and `true` would drop exactly the windows off-screen that a
/// recording's border might not be in yet.
///
/// `SCDisplay`/`SCWindow` are not `Sendable`, so this is a plain struct confined
/// to the main actor (where the whole capture flow lives) rather than a
/// `Sendable` type: it is created and consumed on the same actor, never crossed.
@MainActor
public struct DisplayInventory {
    public let displays: [SCDisplay]
    public let windows: [SCWindow]

    public init(displays: [SCDisplay], windows: [SCWindow]) {
        self.displays = displays
        self.windows = windows
    }

    /// The current set. Throws on the rare failure (no displays, permission
    /// race); callers are expected to surface it rather than capture nothing
    /// silently.
    public static func current() async throws -> DisplayInventory {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return DisplayInventory(displays: content.displays, windows: content.windows)
    }

    /// The `SCDisplay` matching a CoreGraphics display ID, if present.
    public func display(matching id: CGDirectDisplayID) -> SCDisplay? {
        displays.first { $0.displayID == id }
    }

    /// The `SCWindow` matching a CoreGraphics window ID, if present. A `nil`
    /// result means the window is not in the current inventory (e.g. a border
    /// window not yet on screen); callers exclude it best-effort rather than
    /// failing the capture.
    public func window(matching id: CGWindowID) -> SCWindow? {
        windows.first { $0.windowID == id }
    }
}
