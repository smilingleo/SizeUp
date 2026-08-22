import CoreGraphics
import ScreenCaptureKit

/// One-shot screen capture via `SCScreenshotManager`.
///
/// The class method `captureImage(contentFilter:configuration:completionHandler:)`
/// is the 14.0-floor API (the newer `captureScreenshot…`/`SCScreenshotConfiguration`
/// pair is macOS 26-only and would not build on the floor). `SCStreamConfiguration`
/// carries the size and cursor flag as `Int`/`Bool` — not the C int sizes.
///
/// Pull-capture (one `captureImage` per frame) is kept deliberately for parity
/// with the proven Rust implementation; `SCStream` push delivery is a later
/// optimization, not a v1 requirement (see the design's Risks table).
public enum Screenshot {
    /// Capture a display, optionally excluding windows (the recording border)
    /// and including the system cursor.
    ///
    /// Main-actor: the whole capture flow lives there, and `SCDisplay`/the
    /// inventory are not `Sendable`, so the call is confined rather than sent
    /// across actors.
    ///
    /// - Parameters:
    ///   - inventory: The current display/window set, for building the filter.
    ///   - display: The display to capture.
    ///   - excludingWindows: Window IDs to cut out; an ID not in `inventory`
    ///     is dropped from the exclusion list rather than failing the capture
    ///     (the window may have closed between the two calls).
    ///   - pixelSize: Even-rounded output size in pixels (see `even`).
    ///   - showsCursor: Whether the system cursor is drawn in.
    /// - Returns: The captured image, or `nil` on any ScreenCaptureKit failure.
    @MainActor
    public static func capture(
        _ inventory: DisplayInventory,
        display: SCDisplay,
        excludingWindows: [CGWindowID] = [],
        pixelSize: CGSize,
        showsCursor: Bool
    ) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = showsCursor

        let excluded: [SCWindow] = excludingWindows
            .compactMap { inventory.window(matching: $0) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
    }

    /// H.264 and its relatives need even dimensions; an odd value is rounded
    /// down. `0 & ~1 == 0`, so a sub-pixel selection rounds to zero and the
    /// caller treats that as "too small" rather than encoding nothing.
    public static func even(_ value: Int) -> Int { value & ~1 }
}
