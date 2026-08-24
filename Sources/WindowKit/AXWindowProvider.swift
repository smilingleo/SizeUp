import AppKit
import ApplicationServices
import Diagnostics
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
/// ClipShot's own status-item menu is the reason this exists: clicking a menu
/// entry activates ClipShot itself, so `NSWorkspace.shared.frontmostApplication`
/// at the moment `perform` runs is ClipShot — not the app the user actually
/// wants to move a window in. This tracker instead remembers the most
/// recently activated application that was NOT ClipShot, so both the hotkey
/// path (where ClipShot never becomes frontmost) and the menu path (where it
/// briefly does) target the right window.
@MainActor
public final class ActiveApplicationTracker {
    private let ownBundleIdentifier: String?
    private let ownProcessIdentifier: pid_t
    public private(set) var current: RunningApplicationLike?

    public init(
        ownBundleIdentifier: String?,
        ownProcessIdentifier: pid_t,
        initialFrontmostApplication: RunningApplicationLike? = nil
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        self.ownProcessIdentifier = ownProcessIdentifier
        // ClipShot is `LSUIElement`, so launching it does not re-activate
        // whatever app was already frontmost -- no
        // `didActivateApplicationNotification` is ever posted for it. Without
        // this seed, `current` stays nil from launch until the user manually
        // switches apps, so every hotkey (and every menu action) is dead for
        // that entire window. Routing the seed through `noteActivation`
        // rather than assigning `current` directly keeps the self-exclusion
        // check in one place.
        if let initialFrontmostApplication {
            noteActivation(of: initialFrontmostApplication)
        }
    }

    /// Called whenever any application activates. Ignores activations of
    /// ClipShot itself, so `current` always holds the last *other*
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
    ///   which is correct for the hotkey path where ClipShot stays in the
    ///   background. Callers that can also be invoked while ClipShot itself
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
        guard let app = targetApplication() else {
            Log.problem("no target application, so no window to act on")
            return nil
        }
        // No `isTerminated` check on `app` here: this is safe, but only
        // because of `NSRunningApplication`'s own behavior, not anything in
        // this code. Once an app terminates, its `processIdentifier` becomes
        // -1 (never a recycled pid belonging to some other, unrelated
        // process), so `AXUIElementCreateApplication(-1)` produces an
        // element whose attribute copy below fails and this function returns
        // nil rather than acting on the wrong window. If this is ever
        // rewritten to cache a bare `pid_t` instead of holding the live
        // `RunningApplicationLike`, that guarantee disappears and a stale
        // pid could get silently reassigned to a new, unrelated process.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        // The `AXError` is logged, not swallowed. "Nothing happened" is the
        // single most common report about a window manager, and it has two very
        // different causes that are otherwise indistinguishable from outside:
        // no window was found (here) or the application declined the frame
        // (`AXWindow.setFrame`). Both now say so.
        let status = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &raw
        )
        guard status == .success, let rawElement = raw,
              CFGetTypeID(rawElement) == AXUIElementGetTypeID()
        else {
            Log.problem("\(app.bundleIdentifier ?? "pid \(app.processIdentifier)")"
                + " has no focused window Accessibility can see"
                + " (AXFocusedWindow -> \(status.rawValue))")
            return nil
        }
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
            ScreenInfo(
                id: Self.displayID(of: screen) ?? (Self.syntheticIDBase + index),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    /// `CGDirectDisplayID` for a screen, which is stable across sleep/wake,
    /// resolution changes, and replug — unlike the `NSScreen.screens` index
    /// this used to be.
    private static func displayID(of screen: NSScreen) -> Int? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return Int(number.uint32Value)
    }

    /// Used only if AppKit ever fails to report a screen number.
    ///
    /// This does NOT guarantee no collision with a real `CGDirectDisplayID` —
    /// those are opaque `UInt32`s and are routinely in the tens or hundreds of
    /// millions, so a real id could in principle land here. It only has to be a
    /// value real ids are very unlikely to take, since the alternative (a
    /// constant, or the bare index) would alias two screens to the same id and
    /// make "next display" move a window to itself.
    private static let syntheticIDBase = 1_000_000

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
