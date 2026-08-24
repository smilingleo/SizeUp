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

        // While a recording is in flight the menu collapses to the active
        // operation (the design). The region overlay is not a recording, so the
        // window menu is still shown while framing one.
        if context.sessionMode == .recording {
            addRecordingCollapse(menu, context: context, target: target)
            addStandardTail(menu, target: target)
            alignShortcuts(in: menu, context: context)
            return menu
        }

        addCaptureSection(menu, context: context, target: target)

        menu.addItem(submenuItem("Window", target: target, context: context) { sub in
            addBindings(sub, context: context, target: target,
                        [.half(.left), .half(.right), .half(.top), .half(.bottom)])
            sub.addItem(.separator())
            addBindings(sub, context: context, target: target,
                        [.quarter(.upperLeft), .quarter(.upperRight), .quarter(.lowerLeft), .quarter(.lowerRight)])
            sub.addItem(.separator())
            addBindings(sub, context: context, target: target, [.fullScreen, .center, .snapBack])
        })

        menu.addItem(submenuItem("Display", target: target, context: context) { sub in
            addBindings(sub, context: context, target: target, [.display(.next), .display(.previous)])
        })

        addStandardTail(menu, target: target)
        alignShortcuts(in: menu, context: context)

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
        for action in [Action.captureScreenshot, .startRecording] {
            menu.addItem(makeRow(action, context: context, target: target))
        }
        menu.addItem(.separator())
    }

    private func addRecordingCollapse(_ menu: NSMenu, context: Context, target: AnyObject) {
        // Same action, relabelled: the record shortcut is a toggle, so there is
        // no second binding to show here.
        let row = makeRow(.startRecording, context: context, target: target,
                          titleOverride: "Stop Recording")
        menu.addItem(row)
        menu.addItem(.separator())
    }

    // MARK: Standard tail (unchanged except the SizeUp importer → Settings)

    private func addStandardTail(_ menu: NSMenu, target: AnyObject) {
        // The app's own rows are not window actions; without this they read as
        // the tail of the Display group.
        menu.addItem(.separator())

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

        // Hold Option and Help becomes the window probe. An alternate item is
        // the right home for it: it is a diagnostic that exists for one open bug
        // report, it moves the user's focused window around to find out what the
        // window will accept, and nobody should reach it by accident. It sits on
        // Help because that is where someone already is when things are wrong.
        let probe = NSMenuItem(title: "Diagnose Focused Window (writes to the log)",
                               action: #selector(AppDelegate.diagnoseFocusedWindow),
                               keyEquivalent: "")
        probe.keyEquivalentModifierMask = .option
        probe.isAlternate = true
        probe.target = target
        probe.isEnabled = true
        menu.addItem(probe)

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
    /// shortcut)" when unbound, and "(…reason…)" when another app claimed the
    /// keys.
    private func makeRow(_ action: Action, context: Context, target: AnyObject,
                         titleOverride: String? = nil) -> NSMenuItem {
        let binding = context.keymap.bindings.first { $0.action == action }
        let item = NSMenuItem(
            title: titleOverride ?? DefaultKeymap.title(for: action),
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
        return item
    }

    // MARK: The shortcut column

    /// Draw each row's shortcut, right-aligned, the way an ordinary menu does.
    ///
    /// Deliberately *not* `keyEquivalent`. These shortcuts are already registered
    /// globally with Carbon, and a real key equivalent would also fire the row
    /// whenever the menu happened to be open — two screenshots from one press, or
    /// a recording started and stopped again. So the accelerator is drawn as text
    /// and nothing is bound to it.
    ///
    /// One tab stop for the whole menu, computed from the widest row, so the
    /// column lines up instead of ragging.
    private func alignShortcuts(in menu: NSMenu, context: Context) {
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }

        var rows: [(item: NSMenuItem, accelerator: String)] = []
        var widestTitle: CGFloat = 0
        var widestAccelerator: CGFloat = 0
        for item in menu.items {
            guard let action = (item.representedObject as? ActionBox)?.action,
                  let shortcut = context.keymap.bindings
                      .first(where: { $0.action == action })?.shortcut
            else { continue }
            let accelerator = shortcut.displayString
            widestTitle = max(widestTitle, width(item.title))
            widestAccelerator = max(widestAccelerator, width(accelerator))
            rows.append((item, accelerator))
        }
        guard !rows.isEmpty else { return }

        // A right tab stop puts the accelerator's *right* edge at the stop, so it
        // has to leave room for the longest one.
        let gap: CGFloat = 24
        let stop = widestTitle + gap + widestAccelerator
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: stop)]

        for (item, accelerator) in rows {
            let text = NSMutableAttributedString(
                string: item.title,
                attributes: [.font: font, .paragraphStyle: style])
            text.append(NSAttributedString(
                string: "\t" + accelerator,
                attributes: [.font: font, .paragraphStyle: style,
                             .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = text
        }
    }

    private func submenuItem(_ title: String, target: AnyObject, context: Context,
                             _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        // Each submenu gets its own column: aligning them together would leave
        // the short ones with a huge gap.
        alignShortcuts(in: sub, context: context)
        item.submenu = sub
        return item
    }

}

/// Carries an `Action` to a menu row. `representedObject` needs a reference
/// type to hold an enum payload; `nil` marks a non-action row (settings/help/
/// quit route by their own selector and carry none).
final class ActionBox {
    let action: Action?
    init(action: Action?) { self.action = action }
}
