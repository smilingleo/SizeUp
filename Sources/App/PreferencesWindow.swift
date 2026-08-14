import AppKit
import Config
import SwiftUI

/// Owns the single Preferences window and its SwiftUI content.
///
/// AppKit shell, SwiftUI content: the plan calls this a static form where
/// AppKit would be roughly four times the code for the same result.
@MainActor
final class PreferencesWindow {
    private let store: SettingsStore
    private let onChange: () -> Void
    /// Held so a second call to `show()` reuses the same window instead of
    /// building a duplicate. Two windows editing one settings file is a
    /// lost-update bug: whichever saves last wins, silently discarding the
    /// other's edits.
    private var window: NSWindow?
    /// Held alongside the window so a later showing can refresh it from disk.
    private var viewModel: PreferencesViewModel?

    /// `onChange` is a closure, not a reference to `ActionRouter`, so this
    /// type — and the view model it owns — has no reason to know the router
    /// exists. `AppDelegate` supplies `rebuildRouter`.
    init(store: SettingsStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func show() {
        // This is an LSUIElement (menu-bar-only) app, so it is never the
        // active application on its own. Without activating first, the
        // window opens behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            // Re-read before showing: the file may have been hand-edited since
            // the last showing, and editing from a stale view model would write
            // those changes away.
            viewModel?.reload()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = PreferencesViewModel(store: store, onChange: onChange)
        self.viewModel = viewModel
        let hostingController = NSHostingController(rootView: PreferencesView(viewModel: viewModel))
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Sizeup2 Settings"
        // Resizable after all: the skip list grows with however many apps the
        // user adds, and a fixed height either clips it or wastes space. The
        // form's own width is fixed in the view, so only height really varies.
        newWindow.styleMask = [.titled, .closable, .resizable]
        // The window's controller (this object) outlives any single
        // showing, so the window itself must not be deallocated on close —
        // otherwise the next `show()` would find `window` non-nil but
        // pointing at a released object. AppKit's default here is `true`.
        newWindow.isReleasedWhenClosed = false
        // Explicit, because the hosting controller's fitting size for a grouped
        // Form is unreliable; the view sets its own minimum and this gives the
        // skip list some room before the user has to resize.
        newWindow.setContentSize(NSSize(width: 460, height: 560))
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)

        // Deliberately no delegate override of window-closing behaviour:
        // AppDelegate never implements
        // `applicationShouldTerminateAfterLastWindowClosed`, and that
        // method's default is `false`. Sizeup2 is a menu-bar app with no
        // other windows, so relying on the default (rather than adding a
        // redundant override here) is correct and keeps the "do not
        // terminate on close" requirement satisfied at the one place it
        // belongs — the app delegate, not this window.
    }
}
