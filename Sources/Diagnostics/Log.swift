import os

/// The app's log, and the reason it is not `NSLog`.
///
/// Every `NSLog` in this project interpolated a Swift string, and the unified
/// log treats an interpolated value as private data: 31 call sites' worth of
/// diagnostics reached the log as the literal text `(Foundation) <private>`.
/// They were not merely hard to find, they were unreadable, including by the
/// author, and including while diagnosing the bug that led here — a window that
/// would not tile, whose whole explanation was in a redacted line.
///
/// So the privacy decision is made once, here, and it is `.public`. That is
/// safe because of what this app logs: bundle identifiers, window frames,
/// keyboard shortcuts and file paths it was explicitly asked to write. It logs
/// no window titles and no captured pixels. If that ever changes, the argument
/// for `.public` changes with it and this is the one place to revisit.
///
/// A separate leaf target rather than a helper inside one: `WindowKit`,
/// `Config`, `Hotkeys` and `App` all need it, and the layering forbids them
/// from importing each other. A dependency-free target is the only shape that
/// can be shared by all four without weakening a rule.
public enum Log {
    private static let logger = Logger(subsystem: "com.lliu.sizeup2", category: "ClipShot")

    /// One diagnostic line, readable in Console and in `log show` without a
    /// configuration profile to unredact it.
    ///
    /// A plain `String`, not an `@autoclosure`: os_log's own interpolation wants
    /// an escaping closure, so deferring the message here does not compile, and
    /// these sites are all one-per-user-action rather than hot.
    public static func note(_ message: String) {
        logger.log("\(message, privacy: .public)")
    }

    /// A failure the user might reasonably want to know about. Same visibility;
    /// a different level, so `log show --predicate 'messageType == "Error"'`
    /// narrows to the things that went wrong.
    public static func problem(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
