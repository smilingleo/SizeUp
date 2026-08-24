import AppKit
import Config
import Core
import Geometry
import Hotkeys
import WindowKit
import Capture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkeys = HotkeyManager()
    private let store = WindowStateStore()
    // `legacyURL` is the pre-rename location. `migrateFromLegacy()` moves it in at
    // launch, so a rename never loses a preference; then `load()` reads the new spot.
    private let settings = SettingsStore(
        url: SettingsStore.defaultURL,
        legacyURL: SettingsStore.legacyDefaultURL
    )
    private var statusItem: NSStatusItem?
    /// Held so `menuNeedsUpdate` can refresh it without rebuilding the menu.
    private var router: ActionRouter!
    /// Owns the capture side of the merge: the state machine, the overlay, and
    /// the clipboard/save. C1 wires the screenshot flow; the menu and status
    /// icon derive from `session.mode`.
    private let session = CaptureSession(capabilities: [.screenshot, .recording])
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
        settings.migrateFromLegacy()
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
        // A mode change (capture starting or finishing) redraws the icon and
        // refreshes the menu; the delegate's refreshes are idempotent, so the
        // session can over-notify freely.
        session.modeDidChange = { [weak self] _ in
            self?.updateStatusIcon()
            self?.rebuildMenu()
        }
        // The recorder reads the cursor and click-ripple toggles at the moment a
        // recording starts, so changing them takes effect on the next recording
        // without any wiring to invalidate.
        session.captureSettings = { [weak self] in
            self?.settings.settings.capture ?? Config.CaptureSettings()
        }

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
                guard let self else { return }
                // Capture actions go to the session (which enforces the mode
                // exclusions); window actions to the router. This is the split
                // the design calls out: a capture hotkey in the wrong state is
                // ignored there, a window hotkey is simply performed.
                if action.isCapture {
                    self.session.perform(action)
                } else {
                    self.router.perform(action)
                }
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
        item.button?.image = statusIconImage(hasProblem: false)
        statusItem = item
        rebuildMenu()
    }

    /// A shortcut lost to another app is bad; the process-wide event handler
    /// itself failing is worse, since then NO hotkey can ever fire. Either
    /// case must be visible without opening the menu, so the status item's
    /// own icon switches to a warning symbol.
    private func updateStatusIcon() {
        let hasProblem = !hotkeys.registrationFailures.isEmpty || hotkeys.handlerInstallFailed
        let description = hasProblem
            ? "ClipShot (a shortcut could not be claimed)"
            : "ClipShot"
        statusItem?.button?.image = statusIconImage(hasProblem: hasProblem, description: description)
    }

    /// The menu-bar image. The normal state is ClipShot's own template asset;
    /// the problem state is a system warning symbol (assets cannot be tinted a
    /// different *state*, and a template asset that turns into a triangle is
    /// the clearest "something broke" signal). A missing asset falls back to
    /// the old split-rectangle symbol so the icon is never blank.
    private func statusIconImage(hasProblem: Bool, description: String = "ClipShot") -> NSImage? {
        if hasProblem {
            return NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: description
            )
        }
        // The design's second icon state: a recording in flight shows a record
        // dot instead of the normal asset.
        if session.mode == .recording {
            return NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: description
            )
        }
        if let asset = Self.bundleTemplateIcon(named: "statusbar_icon") {
            asset.accessibilityDescription = description
            return asset
        }
        return NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: description)
    }

    /// Loads a bundled PNG as a 21×21 template image. `nil` if the asset is
    /// absent (the caller then falls back to a system symbol).
    private static func bundleTemplateIcon(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: 21, height: 21)
        image.isTemplate = true
        return image
    }

    private func rebuildMenu() {
        // The menu is big enough now (capture section, three submenus, a
        // recording-state collapse) to have its own type: `MenuBuilder` is a
        // pure function of this state. `menu.autoenablesItems = false` is set
        // there, and `menu.delegate = self` lets `menuNeedsUpdate` refresh the
        // one stateful row without rebuilding.
        let context = MenuBuilder.Context(
            keymap: keymap,
            hasAccessibility: AccessibilityPermission.isGranted,
            handlerInstallFailed: hotkeys.handlerInstallFailed,
            registrationFailures: hotkeys.registrationFailures,
            sessionMode: session.mode
        )
        let menu = MenuBuilder().build(context, target: self)
        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox, let action = box.action else { return }
        // Capture actions route to the session (a region overlay / recording);
        // window actions to the router. `Action` is the shared identifier the
        // keymap and the menu both speak.
        if action.isCapture {
            session.perform(action)
        } else {
            router.perform(action)
        }
    }

    @objc func showPreferences() {
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

    /// The Help row: opens the ClipShot documentation (the design keeps it; it
    /// documents the capture side the merge added).
    @objc func openHelp() {
        if let url = URL(string: "https://smilingleo.github.io/clipshot-docs/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    // The status menu has no stateful rows of its own anymore (the login-item
    // row and the SizeUp importer moved to Settings in the redesign), so the
    // `NSMenuDelegate` conformance is retained but does nothing; `rebuildMenu`
    // still assigns `self` as the delegate, which is harmless.
    func menuNeedsUpdate(_ menu: NSMenu) {}
    func menuDidClose(_ menu: NSMenu) {}

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

