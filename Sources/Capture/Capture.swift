import CoreGraphics

/// Screen-capture primitives: one-shot display capture via ScreenCaptureKit,
/// display lookup, and the Screen Recording permission.
///
/// AppKit-free on purpose (layering lint): this target must be testable
/// without a window on screen, and must not import the window-manager
/// modules. `ScreenCaptureKit` and `CoreGraphics` are public API — the
/// private-API quarantine in `SpaceKit` is untouched by the capture merge.

// The real implementation lands in C1 Task 3 (`Permission`, `Display`,
// `Inventory`, `Screenshot`). This file exists so the target and its lint
// row are in place before code lands in them.
public enum Capture {
    /// H.264 and its friends need even pixel dimensions; an odd selection is
    /// rounded down. `0 & ~1 == 0`, so a sub-pixel selection rounds to zero
    /// and the caller treats that as "too small" rather than encoding nothing.
    public static func even(_ value: Int) -> Int { value & ~1 }
}
