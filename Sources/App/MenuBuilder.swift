import AppKit
import Core
import Geometry
import Hotkeys
import WindowKit

/// Builds the status-item menu.
///
/// Extracted from `AppDelegate` when the merge made the menu big enough (a
/// top-level capture section, three submenus of window actions, a
/// recording-state collapse) that one function could no longer be read top to
/// bottom. The delegate hands it everything (the keymap, the permission/hotkey
/// state, the session mode, the live login item) and takes back a finished
/// menu; the behaviors that were the hard-won honesty of M1–M5 — the conflict
/// suffixes, the unavailability notes, the permission banners — move here
/// unchanged.
///
/// Action rows (window *and* capture) route through the delegate's single
/// `menuAction`, which reads the row's `Action` and dispatches capture actions
/// to the session and window actions to the router. This is the same
/// target-action pattern the pre-merge menu used, so nothing about how the rows
/// fire has changed.
final class MenuBuilder {
    /// Everything the menu depends on, in one value, so `build` is a pure
    /// function of state (and the collapse can be reasoned about from it).
    struct Context {
        var keymap: Resolution
        var hasAccessibility: Bool
        var handlerInstallFailed: Bool
        var registrationFailures: [RegistrationFailure]
        var spacesAvailable: Bool
        var sessionMode: CaptureMode
    }

    /// Build the full menu for `context`. `target` is the delegate — every row
    /// posts to it.
    func build(
        _ context: Context,
        target: AnyObject
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addBanners(menu, context: context, target: target)

        // While a *recording* is in flight the menu collapses to the active
        // operation (the design). C1's only capture mode is `.capturing` — the
        // region overlay — which is not a recording, so the window menu is still
        // shown today; the collapse fires from C3 when `.recording`/
        // `.scrollCapturing` become reachable.
        if isRecordingMode(context.sessionMode) {
            addRecordingCollapse(menu, context: context, target: target)
            addStandardTail(menu, target: target)
            return menu
        }

        addCaptureSection(menu, context: context, target: target)

        menu.addItem(submenuItem("Window", target: target) { sub in
            addBindings(sub, context: context, target: target,
                        [.half(.left), .half(.right), .half(.top), .half(.bottom)])
            sub.addItem(.separator())
            addBindings(sub, context: context, target: target,
                        [.quarter(.upperLeft), .quarter(.upperRight), .quarter(.lowerLeft), .quarter(.lowerRight)])
            sub.addItem(.separator())
            addBindings(sub, context: context, target: target, [.fullScreen, .center, .snapBack])
        })

        menu.addItem(submenuItem("Display", target: target) { sub in
            addBindings(sub, context: context, target: target, [.display(.next), .display(.previous)])
        })

        menu.addItem(submenuItem("Spaces", target: target) { sub in
            addBindings(sub, context: context, target: target, [.space(.next), .space(.previous)])
        })

        addStandardTail(menu, target: target)

        return menu
    }

    // MARK: Banners (M1–M5 behavior, unchanged)

    private func addBanners(_ menu: NSMenu, context: Context, target: AnyObject) {
        if !context.hasAccessibility {
            let warning = NSMenuItem(
                title: "Waiting for Accessibility permission…",
                action: #selector(AppDelegate.openAccessibilitySettings),
                keyEquivalent: ""
            )
            warning.target = target
            warning.isEnabled = true
            menu.addItem(warning)
            menu.addItem(.separator())
        }
        if context.handlerInstallFailed {
            let warning = NSMenuItem(
                title: "⚠️ No shortcuts can work: the hotkey system failed to install.",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }
    }

    // MARK: Capture section (top-level, highest-frequency)

    private func addCaptureSection(_ menu: NSMenu, context: Context, target: AnyObject) {
        for action in [Action.captureScreenshot, .startRecording, .toggleScrollCapture] {
            menu.addItem(makeRow(action, context: context, target: target))
        }
        menu.addItem(.separator())
    }

    private func addRecordingCollapse(_ menu: NSMenu, context: Context, target: AnyObject) {
        let isScroll = context.sessionMode == .scrollCapturing
        let row = makeRow(isScroll ? .toggleScrollCapture : .startRecording,
                           context: context, target: target)
        row.title = (isScroll ? "Stop Scroll Capture" : "Stop Recording")
            + "  " + (isScroll ? "⌃⌘S" : "⌃⌘Z")
        menu.addItem(row)
        menu.addItem(.separator())
    }

    // MARK: Standard tail (unchanged except the SizeUp importer → Settings)

    private func addStandardTail(_ menu: NSMenu, target: AnyObject) {
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(AppDelegate.showPreferences),
                                  keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = target
        settings.isEnabled = true
        menu.addItem(settings)

        let help = NSMenuItem(title: "Help",
                              action: #selector(AppDelegate.openHelp),
                              keyEquivalent: "")
        help.target = target
        help.isEnabled = true
        menu.addItem(help)

        let quit = NSMenuItem(title: "Quit ClipShot",
                              action: #selector(AppDelegate.quit),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = target
        quit.isEnabled = true
        menu.addItem(quit)
    }

    // MARK: Row construction

    private func addBindings(_ sub: NSMenu, context: Context, target: AnyObject, _ actions: [Action]) {
        for action in actions {
            sub.addItem(makeRow(action, context: context, target: target))
        }
    }

    /// One action row, with the honest suffixes M1–M5 established: "(no
    /// shortcut)" when unbound, "(…reason…)" when another app claimed the keys,
    /// and "(unavailable on this macOS)" beside a Space item whose private API
    /// did not resolve.
    private func makeRow(_ action: Action, context: Context, target: AnyObject) -> NSMenuItem {
        let binding = context.keymap.bindings.first { $0.action == action }
        let item = NSMenuItem(
            title: DefaultKeymap.title(for: action),
            action: #selector(AppDelegate.menuAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.isEnabled = true
        item.representedObject = ActionBox(action: action)

        item.toolTip = binding?.shortcut?.displayString ?? "No shortcut"
        if binding?.shortcut == nil { item.title += "  (no shortcut)" }
        if !context.handlerInstallFailed, let shortcut = binding?.shortcut,
           let failure = context.registrationFailures.first(where: { $0.shortcut == shortcut }) {
            item.title += "  (\(failure.explanation))"
        }
        if case .space = action, !context.spacesAvailable {
            item.title += "  (unavailable on this macOS)"
            item.toolTip =
                "ClipShot moves windows between Spaces using a private system interface "
                + "that this version of macOS does not provide."
        }
        return item
    }

    private func submenuItem(_ title: String, target: AnyObject,
                             _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        return item
    }

    private func isRecordingMode(_ mode: CaptureMode) -> Bool {
        mode == .recording || mode == .scrollCapturing
    }
}

/// Carries an `Action` to a menu row. `representedObject` needs a reference
/// type to hold an enum payload; `nil` marks a non-action row (settings/help/
/// quit route by their own selector and carry none).
final class ActionBox {
    let action: Action?
    init(action: Action?) { self.action = action }
}
