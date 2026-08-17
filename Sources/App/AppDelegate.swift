import AppKit
import Config
import Core
import Geometry
import Hotkeys
import WindowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkeys = HotkeyManager()
    private let store = WindowStateStore()
    private let settings = SettingsStore(url: SettingsStore.defaultURL)
    private var statusItem: NSStatusItem?
    /// Held so `menuNeedsUpdate` can refresh it without rebuilding the menu.
    private weak var launchAtLoginItem: NSMenuItem?
    /// Surfaced in the login item's tooltip; an NSLog-only error is invisible.
    private var lastLaunchAtLoginError: String?
    private var router: ActionRouter!
    /// Constructed lazily (see `showPreferences`) so it captures
    /// `rebuildRouter` only once the router's dependencies are ready, and
    /// reused thereafter so a second click reuses the same window.
    private var preferencesWindow: PreferencesWindow?
    private let activeApplicationTracker = ActiveApplicationTracker(
        ownBundleIdentifier: Bundle.main.bundleIdentifier,
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        initialFrontmostApplication: NSWorkspace.shared.frontmostApplication
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.load()
        rebuildRouter()
        // Before the status item is built, and independently of whether
        // Accessibility has been granted. `resolveKeymap` used to run only
        // inside `registerHotkeys`, which is gated on that permission, so on any
        // launch without it the menu listed the DEFAULT shortcuts while the
        // Shortcuts tab showed the real ones — and an unbound action appeared
        // bound.
        resolveKeymap()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        makeStatusItem()

        if AccessibilityPermission.isGranted {
            registerHotkeys()
        } else {
            AccessibilityPermission.prompt()
            waitForPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// The keymap actually in force, defaults merged with the user's overrides.
    ///
    /// Held rather than recomputed at each use so the status menu cannot disagree
    /// with what is registered: the menu shows each action's shortcut, and reading
    /// `DefaultKeymap` there would confidently display the wrong keys for every
    /// rebound action.
    private var keymap = KeymapResolver.resolve(overrides: [])

    /// Translates the persisted DTOs into the domain type `Core` merges.
    ///
    /// `Core` must not depend on `Config` and `Config` must not import Carbon, so
    /// this crossing has to happen somewhere; it happens here, where it is a
    /// `compactMap` whose correctness is visible by inspection. The parts with
    /// decisions in them are in `Config.ShortcutSetting.resolved`, which drops
    /// unknown identifiers and modifier-less keys, and in `KeymapResolver`.
    private func resolveKeymap() {
        keymap = KeymapResolver.resolve(overrides: coreOverrides(from: settings.settings))
    }

    /// Rebuilt rather than mutated when settings change.
    ///
    /// Every field of `ActionRouter` except the injected `WindowStateStore` is
    /// configuration, so a fresh router with the same store is equivalent to
    /// mutating six properties and cannot end up half-applied. Reusing `store`
    /// is the point: a preferences change must not cost the user their Snap Back
    /// origins.
    /// Built once and reused. Resolving the private symbols is cheap, but
    /// `isAvailable` is read while building the menu and it should not depend on
    /// how many times the router has been rebuilt.
    private let spaces = SystemSpaceController()

    private func rebuildRouter() {
        let screens = SystemScreenProvider()
        let current = settings.settings
        router = ActionRouter(
            screens: screens,
            windows: AXWindowProvider(screens: screens) { [activeApplicationTracker] in
                activeApplicationTracker.current
            },
            store: store,
            gaps: current.gaps.resolved,
            spans: current.resolvedCycle,
            skipList: Set(current.skippedBundleIdentifiers),
            spaces: spaces,
            followsWindowToSpace: current.followsWindowToSpace
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }
        activeApplicationTracker.noteActivation(of: app)
    }

    /// Idempotent: unregisters first, so this doubles as "re-register after a
    /// rebind". Without the unregister, every rebind would leave the previous
    /// shortcut live and `RegisterEventHotKey` would refuse the new one as
    /// already claimed by this app.
    private func registerHotkeys() {
        resolveKeymap()
        // Re-registering during recording would restore exactly the trap
        // `suspendHotkeys` exists to avoid: the General tab saving, or a SizeUp
        // import finishing, would re-arm the hotkeys under a recorder that is
        // still listening, and the next keystroke would move a window instead of
        // being recorded. The menu is still refreshed, so nothing looks stale.
        guard !isRecording else {
            updateStatusIcon()
            rebuildMenu()
            return
        }
        hotkeys.unregisterAll()
        for binding in keymap.bindings {
            guard let shortcut = binding.shortcut else { continue }
            let action = binding.action
            hotkeys.register(shortcut) { [weak self] in
                self?.router.perform(action)
            }
        }
        updateStatusIcon()
        rebuildMenu()
    }

    /// Releases every hotkey so the shortcut recorder can see keystrokes.
    ///
    /// A registered Carbon hotkey consumes its keystroke before the focused
    /// application receives it, so a recorder built on a local event monitor is
    /// blind to exactly the shortcuts a user wants to change: pressing the
    /// current binding would perform its action instead of being recorded.
    private func suspendHotkeys() {
        isRecording = true
        hotkeys.unregisterAll()
    }

    /// Paired with `suspendHotkeys`. Must run even if the Preferences window is
    /// closed mid-recording, or the app stays silently inert with every shortcut
    /// released and no indication why.
    private func resumeHotkeys() {
        isRecording = false
        guard AccessibilityPermission.isGranted else { return }
        registerHotkeys()
    }

    /// True only while the shortcut recorder is listening.
    private var isRecording = false

    /// The permission dialog is asynchronous and grants without relaunching,
    /// so poll until it is granted, then register.
    private func waitForPermission() {
        guard !AccessibilityPermission.isGranted else {
            registerHotkeys()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.waitForPermission() }
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: "Sizeup2"
        )
        statusItem = item
        rebuildMenu()
    }

    /// A shortcut lost to another app is bad; the process-wide event handler
    /// itself failing is worse, since then NO hotkey can ever fire. Either
    /// case must be visible without opening the menu, so the status item's
    /// own icon switches to a warning symbol.
    private func updateStatusIcon() {
        let hasProblem = !hotkeys.registrationFailures.isEmpty || hotkeys.handlerInstallFailed
        let symbolName = hasProblem ? "exclamationmark.triangle" : "rectangle.split.2x1"
        let description = hasProblem
            ? "Sizeup2 (a shortcut could not be claimed)"
            : "Sizeup2"
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // Without this, AppKit recomputes every item's enabled state from
        // whether its target responds to the action, which silently discards
        // the `isEnabled = false` set on the login item below.
        menu.autoenablesItems = false
        menu.delegate = self

        if !AccessibilityPermission.isGranted {
            let warning = NSMenuItem(
                title: "Waiting for Accessibility permission…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        if hotkeys.handlerInstallFailed {
            let warning = NSMenuItem(
                title: "⚠️ No shortcuts can work: the hotkey system failed to install.",
                action: nil,
                keyEquivalent: ""
            )
            // Explicit, because `autoenablesItems` is off: an informational
            // banner would otherwise draw as an enabled, clickable-looking row.
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        for binding in keymap.bindings {
            let action = binding.action
            let item = NSMenuItem(
                title: DefaultKeymap.title(for: action),
                action: #selector(menuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ActionBox(action: action)
            // An action the user deliberately unbound stays listed and clickable —
            // the menu is the only way to invoke it once it has no key.
            item.toolTip = binding.shortcut?.displayString ?? "No shortcut"
            if binding.shortcut == nil { item.title += "  (no shortcut)" }
            // When the handler failed to install, every shortcut carries that
            // same reason and the banner above already says so once. Repeating
            // it on all 13 items buries the banner.
            if !hotkeys.handlerInstallFailed, let shortcut = binding.shortcut,
                let failure = hotkeys.failure(for: shortcut) {
                // Name the reason. "unavailable" gave the user no way to tell a
                // bug in our keymap from SizeUp still holding the shortcut.
                item.title += "  (\(failure.explanation))"
            }
            // A Spaces action whose private API did not resolve would otherwise
            // sit there looking identical to one that works, and do nothing when
            // clicked. Saying so is the difference between a known limitation on
            // a future macOS and an apparently broken app.
            if case .space = action, !spaces.isAvailable {
                item.title += "  (unavailable on this macOS)"
                item.toolTip =
                    "Sizeup2 moves windows between Spaces using a private system interface "
                    + "that this version of macOS does not provide."
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        // `autoenablesItems` is off (set where the menu is created), so every new item needs
        // this set explicitly or it renders greyed out and unclickable.
        // This exact bug has shipped twice already in this project (the
        // shortcut menu, then the login item) — see the M3 plan.
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

        let importItem = NSMenuItem(
            title: "Import Shortcuts from SizeUp…",
            action: #selector(importFromSizeUp),
            keyEquivalent: ""
        )
        importItem.target = self
        // Offered only when there is something to import. Shown-but-disabled
        // rather than hidden, so a user who expected it can see that it exists
        // and that SizeUp's preferences were not found, rather than concluding
        // the feature is missing.
        let sizeUpPresent = FileManager.default.fileExists(
            atPath: SizeUpImporter.defaultURL.path
        )
        importItem.isEnabled = sizeUpPresent
        if !sizeUpPresent {
            importItem.toolTip = "No SizeUp preferences found at \(SizeUpImporter.defaultURL.path)"
        }
        menu.addItem(importItem)

        let launch = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        menu.addItem(launch)
        launchAtLoginItem = launch
        refreshLaunchAtLoginItem()

        let quit = NSMenuItem(title: "Quit Sizeup2", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        router.perform(box.action)
    }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow(
                store: settings,
                onChange: { [weak self] in
                    self?.rebuildRouter()
                    // Shortcuts are part of settings now, so a change may have
                    // rebound a key. Re-registering unconditionally is cheaper
                    // than working out whether it did, and getting that wrong
                    // leaves the old key live and the new one refused.
                    self?.registerHotkeys()
                },
                onRecordingChange: { [weak self] isRecording in
                    if isRecording {
                        self?.suspendHotkeys()
                    } else {
                        self?.resumeHotkeys()
                    }
                }
            )
        }
        preferencesWindow?.show()
    }

    /// Confirms, imports, then reports — all three, because this replaces
    /// shortcuts the user may have spent time setting up.
    ///
    /// An `NSAlert` rather than the tooltips M2 settled on for the login item:
    /// that state changes behind the app's back and has no moment to interrupt,
    /// whereas this is a destructive action the user just chose, so the one
    /// moment they are definitely looking is now.
    @objc private func importFromSizeUp() {
        let result = SizeUpImporter.read(at: SizeUpImporter.defaultURL)

        guard !result.overrides.isEmpty else {
            let empty = NSAlert()
            empty.messageText = "Nothing to import"
            empty.informativeText = result.skipped.isEmpty
                ? "SizeUp's preferences were found but contain no shortcuts."
                : "None of SizeUp's \(result.skipped.count) shortcut entries could be read."
            empty.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Import \(result.overrides.count) shortcuts from SizeUp?"
        confirm.informativeText =
            "This replaces every shortcut currently set in Sizeup2. "
            + "You can undo it with Restore Defaults in Settings, "
            + "which returns to Sizeup2's own defaults rather than to whatever you had before."
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let outcome = NSAlert()
        do {
            try settings.update { $0.shortcutOverrides = result.overrides }
            rebuildRouter()
            registerHotkeys()
            preferencesWindow?.refresh()
            outcome.messageText = "Imported \(result.overrides.count) shortcuts"
            var detail = "Sizeup2 is now using SizeUp's shortcuts."
            if !result.skipped.isEmpty {
                // Naming them, because a partial import that looks total is how a
                // user ends up pressing a key that will never work again.
                detail += " Skipped \(result.skipped.count): "
                    + result.skipped.sorted().joined(separator: ", ") + "."
            }
            // Spaces bindings import but cannot fire yet. Saying so here is the
            // difference between a known limitation and an apparent bug.
            if result.overrides.contains(where: { $0.action.hasPrefix("space.") }) {
                detail += " SizeUp's Spaces shortcuts were imported but do nothing yet."
            }
            outcome.informativeText = detail
        } catch {
            outcome.messageText = "Could not save the imported shortcuts"
            outcome.informativeText = error.localizedDescription
            outcome.alertStyle = .warning
        }
        outcome.runModal()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Re-reads the login-item state from the system.
    ///
    /// Called on every menu open, not just at launch: the user can disable the
    /// login item in System Settings, and a checkmark that kept claiming it was
    /// on would be exactly the silent failure this feature exists to avoid.
    private func refreshLaunchAtLoginItem() {
        guard let item = launchAtLoginItem else { return }
        let state = LaunchAtLogin.state

        item.title = "Open at Login"
        // `.mixed` for requiresApproval: registration succeeded but macOS is
        // waiting for the user to approve it, so neither ticked nor unticked is
        // honest, and showing it unticked makes the toggle look dead.
        switch state {
        case .enabled: item.state = .on
        case .requiresApproval: item.state = .mixed
        case .disabled, .unsupported: item.state = .off
        }
        // Disabled rather than hidden, so its absence is not mistaken for "off".
        item.isEnabled = state != .unsupported

        if let advice = LaunchAtLogin.advice {
            item.toolTip = advice
            if state == .requiresApproval {
                item.title += "  (needs approval)"
            }
        } else {
            item.toolTip = nil
        }
        if let error = lastLaunchAtLoginError {
            item.toolTip = error
            item.title += "  (failed)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
    }

    func menuDidClose(_ menu: NSMenu) {
        // The error describes the click that just happened. Clearing it when the
        // menu closes stops "(failed)" outliving its cause for the rest of the
        // session, e.g. after the user fixes the cause in System Settings.
        lastLaunchAtLoginError = nil
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
            lastLaunchAtLoginError = nil
        } catch {
            // Kept so the next menu build can show it. An NSLog-only failure is
            // invisible in a menu-bar app with no window.
            lastLaunchAtLoginError = error.localizedDescription
            NSLog("Sizeup2: could not change the login item: \(error.localizedDescription)")
        }
        // Rebuild so the checkmark reflects what the system actually did, not
        // what we asked for.
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// `representedObject` needs a reference type to carry an enum payload.
private final class ActionBox {
    let action: Action
    init(action: Action) { self.action = action }
}
