import AppKit
import Capture
import Config
import SwiftUI
import WindowKit

/// The state of the login item, as the General tab shows it.
///
/// Maps the `ServiceManagement` statuses `LaunchAtLogin` already distinguishes,
/// plus the "the call failed" case the old menu's login row surfaced.
enum LoginItemState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unsupported
    case failed
}

/// The view model behind the General tab.
///
/// Reads the three General-tab concerns from the two live sources: the login
/// item (`SMAppService`), the two permissions, and the persisted capture
/// toggles. Re-read on `reload()` (the window shows it fresh each time) so a
/// grant made in System Settings, or a hand-edit of the capture toggles, is
/// visible without a relaunch.
@MainActor
@Observable
final class GeneralViewModel {
    private let store: SettingsStore
    private let onChange: () -> Void

    private(set) var loginState: LoginItemState = .disabled
    private(set) var loginAdvice: String?
    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false
    var showCursorInRecordings = true
    var showClickRipples = true
    var errorMessage: String?

    init(store: SettingsStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
        reload()
    }

    /// Re-read all three sources. Called every time the window is shown, the
    /// same reason the other tabs reload: the file and the system can change
    /// underneath a long-lived window.
    func reload() {
        let settings = store.settings
        showCursorInRecordings = settings.capture.showCursorInRecordings
        showClickRipples = settings.capture.showClickRipples
        accessibilityGranted = AccessibilityPermission.isGranted
        screenRecordingGranted = ScreenCapturePermission.hasAccess
        (loginState, loginAdvice) = Self.readLoginItem()
    }

    /// The toggle's current two-valued state, for the `Toggle`'s `isOn`.
    var isLoginOn: Bool { loginState == .enabled }

    func toggleLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
            errorMessage = nil
            (loginState, loginAdvice) = Self.readLoginItem()
        } catch {
            loginState = .failed
            // Kept and surfaced: an NSLog-only failure is invisible in a
            // menu-bar app whose General tab is the only window.
            errorMessage = "Could not change the login item: \(error.localizedDescription)"
        }
    }

    func setShowsCursorInRecordings(_ value: Bool) {
        commitCapture { $0.showCursorInRecordings = value }
        showCursorInRecordings = value
    }

    func setShowsClickRipples(_ value: Bool) {
        commitCapture { $0.showClickRipples = value }
        showClickRipples = value
    }

    /// Persist only the `capture` object. The other settings fields are left
    /// exactly as the store holds them, so a toggle change here cannot clobber
    /// a gap or a shortcut the user set in another tab.
    private func commitCapture(_ mutate: (inout Config.CaptureSettings) -> Void) {
        do {
            try store.update {
                mutate(&$0.capture)
            }
            errorMessage = nil
            onChange()
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    /// Read the login-item state, mapping `LaunchAtLogin`'s four-way state (and
    /// its advice) into the tab's representation.
    private static func readLoginItem() -> (LoginItemState, String?) {
        let state = LaunchAtLogin.state
        let advice = LaunchAtLogin.advice
        switch state {
        case .enabled: return (.enabled, nil)
        case .disabled: return (.disabled, nil)
        case .requiresApproval: return (.requiresApproval, advice)
        case .unsupported: return (.unsupported, advice)
        }
    }
}

/// Tab 1 of the redesigned Settings: the app-level controls that were in the
/// menu (login item), the two permissions together, and the capture toggles.
///
/// "General" is the app; the old General tab's window content moves to the
/// **Window** tab (see `PreferencesView`).
struct GeneralView: View {
    @Bindable var viewModel: GeneralViewModel

    var body: some View {
        Form {
            loginSection
            permissionsSection
            captureSection
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        // Same trap as the other tabs: without an explicit minimum, a grouped
        // Form in a TabView in an NSHostingController collapses to its title bar.
        .frame(minWidth: 460, minHeight: 520)
    }

    private var loginSection: some View {
        Section("Launch at Login") {
            // The title switches with the state; spelled with a local `let`
            // rather than an inline ternary, which made SwiftUI's ViewBuilder
            // treat the whole row as a `Bool`.
            let title = viewModel.isLoginOn ? "Open ClipShot at login" : "Don't open ClipShot at login"
            Toggle(
                title,
                isOn: Binding(
                    get: { viewModel.isLoginOn },
                    set: { _ in viewModel.toggleLogin() }
                )
            )
            // `.requiresApproval` shows as unticked-plus-advice rather than
            // ticked or dead: it is a third state (registered, awaiting approval)
            // and showing it either way would be a lie.
            if let advice = viewModel.loginAdvice {
                Text(advice).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(
                "Accessibility",
                granted: viewModel.accessibilityGranted
            ) {
                // Opens the pane. The accessibility prompt itself is handled at
                // launch (the menu banner); this is the manual path.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            permissionRow(
                "Screen Recording",
                granted: viewModel.screenRecordingGranted
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// One permission row: a status glyph, the name, and an "Open System
    /// Settings" button.
    private func permissionRow(
        _ name: String,
        granted: Bool,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Text(name)
            Spacer()
            Button(granted ? "Granted" : "Not granted") { openSettings() }
        }
    }

    private var captureSection: some View {
        Section("Capture") {
            Toggle("Show cursor in recordings",
                   isOn: Binding(
                       get: { viewModel.showCursorInRecordings },
                       set: { viewModel.setShowsCursorInRecordings($0) }
                   ))
            Toggle("Show click ripples",
                   isOn: Binding(
                       get: { viewModel.showClickRipples },
                       set: { viewModel.setShowsClickRipples($0) }
                   ))
            Text("These take effect from the next recording.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
