import AppKit
import Config
import SwiftUI

/// Owns the single Preferences window and its SwiftUI content.
///
/// AppKit shell, SwiftUI content: the plan calls this a static form where
/// AppKit would be roughly four times the code for the same result.
@MainActor
final class PreferencesWindow: NSObject {
    private let store: SettingsStore
    private let onChange: () -> Void
    /// Called with `true` when the shortcut recorder starts listening and
    /// `false` when it stops, so `AppDelegate` can release the global hotkeys
    /// for the duration.
    private let onRecordingChange: (Bool) -> Void
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
    /// Held so closing the window can cancel an in-progress recording.
    private var shortcutsViewModel: ShortcutsViewModel?

    init(
        store: SettingsStore,
        onChange: @escaping () -> Void,
        onRecordingChange: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
        super.init()
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
            shortcutsViewModel?.reload()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = PreferencesViewModel(store: store, onChange: onChange)
        self.viewModel = viewModel
        let shortcuts = ShortcutsViewModel(
            store: store,
            onChange: onChange,
            onRecordingChange: onRecordingChange
        )
        self.shortcutsViewModel = shortcuts
        let hostingController = NSHostingController(
            rootView: PreferencesTabs(general: viewModel, shortcuts: shortcuts)
        )
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "ClipShot Settings"
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
        // Wider than M3's 460: the shortcuts tab needs room for an action name,
        // a shortcut, and two buttons on one line without truncating.
        newWindow.setContentSize(NSSize(width: 520, height: 580))
        newWindow.center()
        newWindow.delegate = self
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)

        // A delegate IS now set, but only to cancel recording on close — see
        // `windowWillClose`. Deliberately still no override of window-closing
        // behaviour itself:
        // AppDelegate never implements
        // `applicationShouldTerminateAfterLastWindowClosed`, and that
        // method's default is `false`. ClipShot is a menu-bar app with no
        // other windows, so relying on the default (rather than adding a
        // redundant override here) is correct and keeps the "do not
        // terminate on close" requirement satisfied at the one place it
        // belongs — the app delegate, not this window.
    }
}

extension PreferencesWindow: NSWindowDelegate {
    /// Cancels any in-progress recording when the window closes.
    ///
    /// Recording releases every global hotkey so the recorder can see
    /// keystrokes. If the user starts recording and then closes the window —
    /// which is the obvious way to back out — nothing else would ever call the
    /// paired resume, and the app would sit there with no working shortcuts and
    /// no indication why. That failure is silent and survives until relaunch,
    /// which makes it worth a delegate on its own.
    func windowWillClose(_ notification: Notification) {
        shortcutsViewModel?.cancelRecording()
    }

    /// Also on losing key focus, for the same reason.
    ///
    /// Closing the window is the obvious way to back out, but it is not the only
    /// one: command-tabbing away, or clicking any other window, leaves the
    /// recorder listening for a keystroke it can no longer receive while every
    /// hotkey stays released. The app then appears completely dead, with the
    /// Settings window sitting open showing "Press a key" in a row the user has
    /// forgotten about.
    func windowDidResignKey(_ notification: Notification) {
        shortcutsViewModel?.cancelRecording()
    }

    /// Re-reads the settings file into both tabs, for a change made from
    /// outside this window.
    ///
    /// The SizeUp import writes shortcuts straight to the file. With the window
    /// open, the Shortcuts tab went on displaying the bindings from before the
    /// import — a keymap that is emphatically not the one now registered.
    /// Harmless when importing the file the defaults came from, since nothing
    /// changes; wrong for anybody else's.
    func refresh() {
        guard window != nil else { return }
        viewModel?.reload()
        shortcutsViewModel?.reload()
    }
}
