import AppKit
import Config
import Core
import Geometry
import Hotkeys
import SwiftUI

/// The Preferences window's three tabs.
///
/// **General** — app-level: login item, both permissions, the capture toggles
/// (the redesigned Tab 1). **Window** — the window-manager settings that
/// used to live in "General" (gaps, spaces, cycling, skip list); renamed to
/// "Window" because "General" now means the app-level tab. **Shortcuts** — the
/// unified recorder for all 18 bound actions.
///
/// A separate type rather than adding a case to `PreferencesView` because that
/// view is the *Window* tab's content; `PreferencesTabs` composes the three.
struct PreferencesTabs: View {
    @Bindable var general: GeneralViewModel
    @Bindable var window: PreferencesViewModel
    @Bindable var shortcuts: ShortcutsViewModel

    var body: some View {
        TabView {
            GeneralView(viewModel: general)
                .tabItem { Text("General") }
            PreferencesView(viewModel: window)
                .tabItem { Text("Window") }
            ShortcutsView(viewModel: shortcuts)
                .tabItem { Text("Shortcuts") }
        }
    }
}

/// One row's worth of display state: an action, its resolved shortcut, and
/// whether it is the row currently recording.
struct ShortcutRow: Identifiable {
    let action: Action
    let title: String
    let shortcut: Shortcut?
    var id: String { ActionIdentifier.identifier(for: action) }
}

/// The view model behind the Shortcuts tab.
///
/// Matches `PreferencesViewModel`'s shape deliberately: `@MainActor`,
/// `@Observable`, and a private `save()` that is the only place overrides
/// reach `SettingsStore`. This is where recording state lives — the event
/// monitor and the flag that says whether one is installed — because
/// `PreferencesWindow` must be able to cancel it from outside the view (on
/// window close) without the view existing to hold `@State`.
@MainActor
@Observable
final class ShortcutsViewModel {
    private let store: SettingsStore
    private let onChange: () -> Void
    private let onRecordingChange: (Bool) -> Void

    private(set) var rows: [ShortcutRow] = []

    /// The 18 bound actions in their two display sections, in `DefaultKeymap`
    /// order: the three capture actions, then the fifteen window actions.
    /// Split on `Action.isCapture` rather than position so the grouping holds
    /// if the keymap order is ever changed.
    var captureRows: [ShortcutRow] { rows.filter { $0.action.isCapture } }
    var windowRows: [ShortcutRow] { rows.filter { !$0.action.isCapture } }
    /// The action whose row is showing "Press keys…". `nil` when nothing is
    /// recording, which the view uses to disable every other row's buttons —
    /// two recordings at once would each install a monitor and both never end
    /// cleanly.
    private(set) var recordingAction: Action?
    /// Names the action that lost its binding to the most recent recording,
    /// so the row can explain itself. Cleared on the next recording or on
    /// `reload()`.
    private(set) var displacedMessage: String?
    /// Explains a conflict that was already in the settings file when it was
    /// read, as opposed to one the user just created by recording.
    private(set) var conflictMessage: String?
    var errorMessage: String?

    private var monitor: Any?

    init(
        store: SettingsStore,
        onChange: @escaping () -> Void,
        onRecordingChange: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
        adopt(store.settings)
    }

    /// Re-reads the settings file and adopts it. Called every time the
    /// window is shown, for the same reason `PreferencesViewModel.reload()`
    /// exists: a view model built from a stale read would write the user's
    /// hand edits away on the next rebind.
    func reload() {
        cancelRecording()
        store.load()
        adopt(store.settings)
        // Publishing what was just read, like its sibling in the General tab.
        // Without this the tab displayed a hand-edited keymap that had never
        // been registered, and only looked right because the General tab
        // happened to reload first — load-bearing ordering that nothing stated.
        onChange()
    }

    private func adopt(_ settings: Config.Settings) {
        let resolution = KeymapResolver.resolve(overrides: coreOverrides(from: settings))
        rows = resolution.bindings.map {
            ShortcutRow(action: $0.action, title: DefaultKeymap.title(for: $0.action), shortcut: $0.shortcut)
        }
        // A hand-edited file can put two actions on one key. `resolve` unbinds
        // the loser to keep the registration honest, but until this was
        // rendered the user simply found an action they never touched had lost
        // its shortcut, with the explanation computed and thrown away.
        conflictMessage = Self.describe(resolution.conflicts)
    }

    /// Reports what a hand-edited file asked for, naming the winner explicitly.
    ///
    /// `conflicts` carries each group in `DefaultKeymap` order, which is the order
    /// `unbindLosers` keeps, so the first name is the action still in effect.
    /// Sorting the names inside a group therefore cannot be done: an earlier
    /// version said "only the first of each is in effect" over an alphabetised
    /// list, so for `half.left` against `fullScreen` it named Full Screen as the
    /// survivor when Left Half was. The groups themselves are sorted, because the
    /// underlying dictionary has no order and a message that reshuffles between
    /// launches reads like a different problem each time.
    private static func describe(_ conflicts: [Shortcut: [Action]]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        let described = conflicts
            .compactMap { shortcut, actions -> String? in
                guard let winner = actions.first else { return nil }
                let losers = actions.dropFirst().map { DefaultKeymap.title(for: $0) }
                guard !losers.isEmpty else { return nil }
                return "\(shortcut.displayString) is set for "
                    + "\(DefaultKeymap.title(for: winner)) and "
                    + "\(losers.joined(separator: " and "))"
            }
            .sorted()
        guard !described.isEmpty else { return nil }
        let lead = described.count == 1
            ? "Your settings file gives one shortcut to more than one action: "
            : "Your settings file gives \(described.count) shortcuts to more than one action: "
        return lead + described.joined(separator: "; ")
            + ". Only the first named in each is in effect; the rest have been unbound."
    }

    /// Starts recording for `action`. Suspends the global hotkeys for the
    /// duration — see the plan's "Hotkeys must be suspended while recording"
    /// — because a registered Carbon hotkey consumes its keystroke before
    /// this event monitor ever sees it, so the user could not rebind any
    /// shortcut that is currently bound, which is the common case.
    func startRecording(for action: Action) {
        cancelRecording()
        recordingAction = action
        displacedMessage = nil
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            self?.handle(event)
            return event
        }
    }

    /// Cancels recording without changing anything. Safe to call when
    /// nothing is recording — `PreferencesWindow` calls this unconditionally
    /// on window close, and `startRecording` calls it defensively before
    /// starting a new one.
    func cancelRecording() {
        guard recordingAction != nil else { return }
        removeMonitor()
        recordingAction = nil
        onRecordingChange(false)
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Returns the event unmodified. `nil` would also swallow it from every
    /// other app-local monitor and from the window itself, and the recorder
    /// has no reason to prevent that — it only watches.
    private func handle(_ event: NSEvent) {
        guard let action = recordingAction else { return }

        if event.keyCode == escapeKeyCode, !hasRealModifier(event.modifierFlags) {
            cancelRecording()
            return
        }

        // A key-down with no real modifier is not a valid global hotkey (see
        // `ActionIdentifier.hasRealModifier`) and must not end recording:
        // the user's next stray keystroke — Shift alone releases a keyDown
        // for the letter it shifted — would otherwise silently bind
        // something invalid instead of waiting for the real chord.
        guard hasRealModifier(event.modifierFlags) else { return }

        let shortcut = Shortcut(
            keyCode: UInt32(event.keyCode),
            modifierFlags: event.modifierFlags.rawValue
        )
        removeMonitor()
        recordingAction = nil
        onRecordingChange(false)
        assign(shortcut, to: action)
    }

    /// Delegates to `Config`, which is what will judge the recorded value on
    /// the next load. A separate copy here could drift and let the recorder
    /// accept a chord that is then discarded at launch — a shortcut that works
    /// until relaunch.
    private func hasRealModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        Config.ActionIdentifier.hasRealModifier(flags.rawValue)
    }

    /// `kVK_Escape`. Spelled out because `Hotkeys` deliberately does not
    /// re-export Carbon, and a bare 53 is unreadable.
    private let escapeKeyCode: UInt16 = 53

    private func assign(_ shortcut: Shortcut, to action: Action) {
        let (nextOverrides, displaced) = KeymapResolver.assigning(
            shortcut,
            to: action,
            in: currentOverrides()
        )
        displacedMessage = nil
        save(nextOverrides)
        // Only after the save, and only if it succeeded: announcing a
        // displacement that failed to persist would sit next to the red error
        // message contradicting it, and the shortcut would still be where it was.
        guard errorMessage == nil, !displaced.isEmpty else { return }
        let names = displaced.map { DefaultKeymap.title(for: $0) }
            .sorted()
            .joined(separator: ", ")
        let subject = displaced.count == 1 ? "which now has" : "which now have"
        displacedMessage =
            "\(shortcut.displayString) was taken from \(names), \(subject) no shortcut."
    }

    /// Persists an explicit unbind for `action`. Distinct from simply
    /// removing any existing override: an absent entry means "use the
    /// default", and the default is very likely the shortcut the user just
    /// asked to clear.
    func clear(_ action: Action) {
        displacedMessage = nil
        var overrides = currentOverrides()
        overrides.removeAll { $0.action == action }
        overrides.append(Core.ShortcutOverride(action: action, keyCode: nil, modifierFlags: 0))
        save(overrides)
    }

    /// Clears every override, reverting to `DefaultKeymap` entirely.
    func restoreDefaults() {
        displacedMessage = nil
        save([])
    }

    private func currentOverrides() -> [Core.ShortcutOverride] {
        coreOverrides(from: store.settings)
    }

    // MARK: Shortcut importers (moved here from the menu in the redesign)

    /// Whether each importer has anything to read, for the button disabled +
    /// tooltip states. A checked file that parses empty still offers the
    /// import (it reports "nothing to import") — but a *missing* file means the
    /// button is disabled with a tooltip, the way the old menu item did.
    var sizeUpPresent: Bool {
        FileManager.default.fileExists(atPath: SizeUpImporter.defaultURL.path)
    }
    var clipShotPresent: Bool {
        FileManager.default.fileExists(atPath: ClipShotImporter.defaultURL.path)
    }

    /// The tooltip explaining why an import button is disabled. Kept on the
    /// model (not the view) because it names a file path — the view would have
    /// to import `Config`'s importers just to build a string, and a ternary
    /// `nil` in the view body does not type-check against SwiftUI's `help`.
    var sizeUpTooltip: String? {
        sizeUpPresent ? nil : "No SizeUp preferences found at \(SizeUpImporter.defaultURL.path)"
    }
    var clipShotTooltip: String? {
        clipShotPresent ? nil : "No ClipShot config found at \(ClipShotImporter.defaultURL.path)"
    }

    func importFromSizeUp() {
        let result = SizeUpImporter.read(at: SizeUpImporter.defaultURL)
        performImport(result.overrides, skipped: result.skipped, source: "SizeUp")
    }

    func importFromClipShot() {
        let result = ClipShotImporter.read(at: ClipShotImporter.defaultURL)
        performImport(result.overrides, skipped: result.skipped, source: "ClipShot")
    }

    /// The shared confirm → import → report flow. Both importers replace *all*
    /// shortcut overrides, so both carry the same destructive-action treatment
    /// the SizeUp import always had: a confirm that says so, and a report that
    /// names what was imported and what was skipped.
    private func performImport(
        _ overrides: [ShortcutSetting],
        skipped: [String],
        source: String
    ) {
        guard !overrides.isEmpty else {
            let empty = NSAlert()
            empty.messageText = "Nothing to import"
            empty.informativeText = source + "'s preferences were found but contain no shortcuts."
            empty.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText =
            "Import \(overrides.count) shortcut\(overrides.count == 1 ? "" : "s") from \(source)?"
        confirm.informativeText =
            "This replaces every shortcut currently set in ClipShot. "
            + "You can undo it with Restore Defaults, which returns to ClipShot's own defaults."
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.update { $0.shortcutOverrides = overrides }
            adopt(store.settings)
            onChange()
            let outcome = NSAlert()
            outcome.messageText = "Imported \(overrides.count) shortcut\(overrides.count == 1 ? "" : "s") from \(source)"
            outcome.informativeText = skipped.isEmpty
                ? source + "'s shortcuts are now in use."
                : "Skipped \(skipped.joined(separator: ", ")): unreadable or invalid."
            outcome.runModal()
        } catch {
            errorMessage = "Couldn't save the imported shortcuts: \(error.localizedDescription)"
        }
    }

    private func save(_ overrides: [Core.ShortcutOverride]) {
        do {
            try store.update {
                $0.shortcutOverrides = overrides.map {
                    ShortcutSetting(
                        action: ActionIdentifier.identifier(for: $0.action),
                        keyCode: $0.keyCode,
                        modifierFlags: $0.modifierFlags
                    )
                }
            }
            errorMessage = nil
            adopt(store.settings)
            onChange()
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}

/// The single translation from stored settings to `Core`'s input type.
///
/// There were three identical copies of this `compactMap`, plus a fourth in the
/// test that was supposed to validate it — so the test validated its own copy
/// and any of the three could have been mutated without failing anything.
func coreOverrides(from settings: Config.Settings) -> [Core.ShortcutOverride] {
    settings.shortcutOverrides.compactMap { setting in
        guard let resolved = setting.resolved else { return nil }
        return Core.ShortcutOverride(
            action: resolved.action,
            keyCode: resolved.keyCode,
            modifierFlags: resolved.modifierFlags
        )
    }
}

struct ShortcutsView: View {
    @Bindable var viewModel: ShortcutsViewModel

    // Split into computed sections, same reason as `PreferencesView`: a
    // single `body` expression over this many rows failed to type-check in
    // reasonable time in the sibling tab, and there is no reason to expect
    // this one to fare better.
    var body: some View {
        Form {
            // Above the rows, not after them. Appended below the rows it
            // sat outside the window and had to be scrolled to, which defeats
            // its entire purpose: the user sees a shortcut disappear from an
            // action they did not touch, and the sentence explaining why is the
            // one thing they cannot see. Measured in the live window.
            if let displacedMessage = viewModel.displacedMessage {
                Section {
                    Text(displacedMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if let conflictMessage = viewModel.conflictMessage {
                Section {
                    Text(conflictMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            Section("Capture") {
                ForEach(viewModel.captureRows) { row in
                    shortcutRow(row)
                }
            }
            Section("Window") {
                ForEach(viewModel.windowRows) { row in
                    shortcutRow(row)
                }
            }
            Section {
                Button("Restore Defaults") { viewModel.restoreDefaults() }
                    .disabled(viewModel.recordingAction != nil)
            }
            // Both importers moved here from the menu in the redesign: the
            // menu's job is invoking actions, configuration lives in one place.
            // Each is disabled + explained when its source file is absent, the
            // way the old SizeUp menu item did.
            Section("Import Shortcuts") {
                Button("Import Shortcuts from SizeUp…") { viewModel.importFromSizeUp() }
                    .disabled(!viewModel.sizeUpPresent)
                    .help(viewModel.sizeUpTooltip ?? "")
                Button("Import Shortcuts from ClipShot…") { viewModel.importFromClipShot() }
                    .disabled(!viewModel.clipShotPresent)
                    .help(viewModel.clipShotTooltip ?? "")
            }
        }
        .formStyle(.grouped)
        // See `PreferencesView`'s note on the same trap: without an explicit
        // minimum, a grouped Form inside a TabView inside an
        // NSHostingController collapses the window to its title bar.
        .frame(minWidth: 460, minHeight: 520)
    }

    private func shortcutRow(_ row: ShortcutRow) -> some View {
        let isRecording = viewModel.recordingAction == row.action
        let anotherIsRecording = viewModel.recordingAction != nil && !isRecording
        return HStack {
            Text(row.title)
            Spacer()
            Text(isRecording ? "Press keys…" : (row.shortcut?.displayString ?? "None"))
                .foregroundStyle(isRecording ? .secondary : .primary)
                .frame(minWidth: 80, alignment: .trailing)
            Button(isRecording ? "Cancel" : "Record") {
                if isRecording {
                    viewModel.cancelRecording()
                } else {
                    viewModel.startRecording(for: row.action)
                }
            }
            .disabled(anotherIsRecording)
            Button("Clear") { viewModel.clear(row.action) }
                .disabled(row.shortcut == nil || anotherIsRecording || isRecording)
        }
    }
}
