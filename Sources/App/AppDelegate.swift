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

    /// Rebuilt rather than mutated when settings change.
    ///
    /// Every field of `ActionRouter` except the injected `WindowStateStore` is
    /// configuration, so a fresh router with the same store is equivalent to
    /// mutating six properties and cannot end up half-applied. Reusing `store`
    /// is the point: a preferences change must not cost the user their Snap Back
    /// origins.
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
            skipList: Set(current.skippedBundleIdentifiers)
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }
        activeApplicationTracker.noteActivation(of: app)
    }

    private func registerHotkeys() {
        for (shortcut, action) in DefaultKeymap.bindings {
            hotkeys.register(shortcut) { [weak self] in
                self?.router.perform(action)
            }
        }
        updateStatusIcon()
        rebuildMenu()
    }

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

        for (shortcut, action) in DefaultKeymap.bindings {
            let item = NSMenuItem(
                title: DefaultKeymap.title(for: action),
                action: #selector(menuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ActionBox(action: action)
            item.toolTip = shortcut.displayString
            // When the handler failed to install, every shortcut carries that
            // same reason and the banner above already says so once. Repeating
            // it on all 13 items buries the banner.
            if !hotkeys.handlerInstallFailed, let failure = hotkeys.failure(for: shortcut) {
                // Name the reason. "unavailable" gave the user no way to tell a
                // bug in our keymap from SizeUp still holding the shortcut.
                item.title += "  (\(failure.explanation))"
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
        // `autoenablesItems` is off (see below), so every new item needs
        // this set explicitly or it renders greyed out and unclickable.
        // This exact bug has shipped twice already in this project (the
        // shortcut menu, then the login item) — see the M3 plan.
        settingsItem.isEnabled = true
        menu.addItem(settingsItem)

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
            preferencesWindow = PreferencesWindow(store: settings) { [weak self] in
                self?.rebuildRouter()
            }
        }
        preferencesWindow?.show()
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
