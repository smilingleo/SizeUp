import AppKit
import Config
import Core
import Geometry
import Hotkeys
import SwiftUI

/// The Preferences window's two tabs.
///
/// A separate type rather than adding a case to `PreferencesView` because
/// `PreferencesView` is out of bounds for this task (house rule 3) — this
/// only composes it with the new shortcuts tab.
struct PreferencesTabs: View {
    @Bindable var general: PreferencesViewModel
    @Bindable var shortcuts: ShortcutsViewModel

    var body: some View {
        TabView {
            PreferencesView(viewModel: general)
                .tabItem { Text("General") }
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

    /// Reports what a hand-edited file asked for, in a stable order — the
    /// underlying dictionary has none, and a message that reshuffles itself
    /// between launches reads like a different problem each time.
    private static func describe(_ conflicts: [Shortcut: [Action]]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        let described = conflicts
            .map { shortcut, actions in
                let names = actions.map { DefaultKeymap.title(for: $0) }.sorted()
                return "\(shortcut.displayString) (\(names.joined(separator: " and ")))"
            }
            .sorted()
        let lead = described.count == 1
            ? "Your settings file gives one shortcut to more than one action: "
            : "Your settings file gives \(described.count) shortcuts to more than one action: "
        return lead + described.joined(separator: "; ")
            + ". Only the first of each is in effect; the others have been unbound."
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
            // Above the rows, not after them. Appended below thirteen rows it
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
            Section("Shortcuts") {
                ForEach(viewModel.rows) { row in
                    shortcutRow(row)
                }
            }
            Section {
                Button("Restore Defaults") { viewModel.restoreDefaults() }
                    .disabled(viewModel.recordingAction != nil)
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
