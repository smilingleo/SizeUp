import AppKit

/// The window levels the capture UI stacks itself at.
///
/// These are collected in one place because they only make sense relative to
/// each other, and because the obvious spelling is a trap:
/// `CGWindowLevelKey.overlayWindow.rawValue` is the *key's* index (15), not the
/// level it names (102). Level 15 lands below the menu bar (24) and the status
/// bar (25), so an overlay set to it fails to dim or cover the menu bar —
/// which is both visibly wrong and a hole in the screenshot.
public enum OverlayLevel {
    /// The dimmed capture surface. Above the menu bar, so the entire screen is
    /// part of the shot and nothing else can be clicked mid-capture.
    public static let overlay = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.overlayWindow)))

    /// The editor toolbar, just above the surface it drives.
    public static let toolbar = NSWindow.Level(rawValue: overlay.rawValue + 1)

    /// For anything that must stay reachable while the overlay is up. A save
    /// dialog opened below the overlay is invisible *and* unreachable, which
    /// leaves the app looking hung with no way to cancel.
    public static let aboveOverlay = NSWindow.Level(rawValue: overlay.rawValue + 2)
}
