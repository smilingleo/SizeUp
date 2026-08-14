import AppKit
import Core
import Geometry
import Hotkeys
import WindowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkeys = HotkeyManager()
    private let store = WindowStateStore()
    private var statusItem: NSStatusItem?
    /// Held so `menuNeedsUpdate` can refresh it without rebuilding the menu.
    private weak var launchAtLoginItem: NSMenuItem?
    private var router: ActionRouter!
    private let activeApplicationTracker = ActiveApplicationTracker(
        ownBundleIdentifier: Bundle.main.bundleIdentifier,
        ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
        initialFrontmostApplication: NSWorkspace.shared.frontmostApplication
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screens = SystemScreenProvider()
        router = ActionRouter(
            screens: screens,
            windows: AXWindowProvider(screens: screens) { [activeApplicationTracker] in
                activeApplicationTracker.current
            },
            store: store,
            gaps: .zero,
            spans: [.half],
            skipList: []
        )

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
        let supported = LaunchAtLogin.isSupported
        item.state = LaunchAtLogin.isEnabled ? .on : .off
        // Disabled rather than hidden, so its absence is not mistaken for "off".
        item.isEnabled = supported
        item.toolTip = supported ? nil : "Move Sizeup2 to /Applications to enable this."
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        } catch {
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
