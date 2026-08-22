import CoreGraphics

/// Whether this process may capture the screen.
///
/// `CGPreflightScreenCaptureAccess` is the "ask without bothering" check and
/// `CGRequestScreenCaptureAccess` is the one-shot system prompt. Both are
/// public API (macOS 10.15+) and need no entitlement beyond the
/// `NSScreenCaptureUsageDescription` in the bundle's Info.plist, which macOS
/// shows in the prompt.
///
/// The capture actions check this at dispatch time, never at launch: the
/// permission is independent of Accessibility, so the app must come up and
/// manage windows fine with only one of the two. A failed capture surfaces a
/// one-time alert with a deep link to the pane (in `App`), matching how the
/// Rust ClipShot handled it.
public enum ScreenCapturePermission {
    /// `true` once the user has granted Screen Recording to this bundle.
    public static var hasAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt. macOS displays the dialog at most once per
    /// app launch; repeated calls after that are no-ops, so it is safe to
    /// call on every failed capture without being obnoxious.
    ///
    /// - Returns: `true` when access is (now) held. The value can still be
    ///   `false` right after the prompt if the user cancelled, so callers
    ///   must re-check `hasAccess` rather than trusting the return alone.
    @discardableResult
    public static func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
