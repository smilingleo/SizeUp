import AppKit
import ApplicationServices
import Geometry

/// The minimal surface `AXWindowProvider` needs from a running application,
/// factored out of `NSRunningApplication` so tests can supply fakes without
/// needing a real running process.
public protocol RunningApplicationLike {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
}

extension NSRunningApplication: RunningApplicationLike {}

/// Tracks which application a window action should target, independent of
/// whichever application happens to be frontmost at the instant an action
/// is performed.
///
/// Sizeup2's own status-item menu is the reason this exists: clicking a menu
/// entry activates Sizeup2 itself, so `NSWorkspace.shared.frontmostApplication`
/// at the moment `perform` runs is Sizeup2 — not the app the user actually
/// wants to move a window in. This tracker instead remembers the most
/// recently activated application that was NOT Sizeup2, so both the hotkey
/// path (where Sizeup2 never becomes frontmost) and the menu path (where it
/// briefly does) target the right window.
@MainActor
public final class ActiveApplicationTracker {
    private let ownBundleIdentifier: String?
    private let ownProcessIdentifier: pid_t
    public private(set) var current: RunningApplicationLike?

    public init(ownBundleIdentifier: String?, ownProcessIdentifier: pid_t) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    /// Called whenever any application activates. Ignores activations of
    /// Sizeup2 itself, so `current` always holds the last *other*
    /// application to become frontmost.
    public func noteActivation(of app: RunningApplicationLike) {
        guard !isSelf(app) else { return }
        current = app
    }

    private func isSelf(_ app: RunningApplicationLike) -> Bool {
        if app.processIdentifier == ownProcessIdentifier { return true }
        if let ownBundleIdentifier, let appBundleIdentifier = app.bundleIdentifier,
            appBundleIdentifier == ownBundleIdentifier
        {
            return true
        }
        return false
    }
}

public struct AXWindowProvider: WindowProviding {
    private let screens: ScreenProviding
    private let targetApplication: () -> RunningApplicationLike?

    /// - Parameter targetApplication: Resolves which application to read the
    ///   focused window from. Defaults to whatever is frontmost right now,
    ///   which is correct for the hotkey path where Sizeup2 stays in the
    ///   background. Callers that can also be invoked while Sizeup2 itself
    ///   is frontmost — the status-item menu — must supply something like
    ///   `ActiveApplicationTracker.current` instead.
    public init(
        screens: ScreenProviding,
        targetApplication: @escaping () -> RunningApplicationLike? = {
            NSWorkspace.shared.frontmostApplication
        }
    ) {
        self.screens = screens
        self.targetApplication = targetApplication
    }

    public func focusedWindow() -> WindowHandle? {
        guard let app = targetApplication() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &raw
        ) == .success, let rawElement = raw, CFGetTypeID(rawElement) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(rawElement, to: AXUIElement.self)

        return AXWindow(
            element: element,
            pid: app.processIdentifier,
            primaryFrame: screens.primaryFrame,
            bundleIdentifier: app.bundleIdentifier
        )
    }
}

public struct SystemScreenProvider: ScreenProviding {
    public init() {}

    public var screens: [ScreenInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            ScreenInfo(id: index, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    /// The Accessibility origin is the top-left of whichever display has a
    /// Cocoa origin of `(0, 0)` — almost always `screens[0]`, but not
    /// guaranteed to be. Falling back to `first` only when no screen sits at
    /// the origin keeps the common case free and avoids assuming display
    /// order encodes anything about coordinate origin.
    public var primaryFrame: CGRect {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame ?? .zero
    }
}
