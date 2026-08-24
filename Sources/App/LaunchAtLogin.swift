import ServiceManagement

/// Registers the app itself as a login item.
///
/// `SMAppService.mainApp` needs no helper bundle and no `LaunchAgents` plist —
/// the app registers itself.
///
/// **This does not work with the project's current ad-hoc signing.** Measured on
/// macOS 26: `SMAppService.mainApp.status` is `.notFound` (raw value 3) both from
/// `/Applications` and from a build directory, because the bundle carries
/// `flags=0x2(adhoc)`. macOS will not register an ad-hoc-signed app as a login
/// item regardless of where it lives. The code below is correct and degrades
/// visibly rather than silently, but the feature stays unavailable until the app
/// is signed with a real identity. Do not "fix" this by moving the app.
@MainActor
enum LaunchAtLogin {
    /// The states worth distinguishing in the UI.
    ///
    /// `requiresApproval` is the one that matters and the one easiest to get
    /// wrong: registration SUCCEEDED, but macOS is waiting for the user to
    /// approve it under System Settings → General → Login Items. Treating it as
    /// "off" produces a dead toggle — the user clicks, nothing appears to
    /// happen, they click again, and the app still will not start at login.
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        /// The system will not register this bundle at all.
        case unsupported
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unsupported
        case .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Whether toggling can achieve anything at all.
    static var isSupported: Bool { state != .unsupported }

    /// True only when the app will genuinely start at login.
    static var isEnabled: Bool { state == .enabled }

    /// What to tell the user about the current state, or nil if nothing needs
    /// saying. Returned rather than logged, because a login item that quietly
    /// did not register is a failure the user would otherwise discover only
    /// after the next reboot.
    static var advice: String? {
        switch state {
        case .enabled, .disabled:
            return nil
        case .requiresApproval:
            return "Approve ClipShot in System Settings → General → Login Items."
        case .unsupported:
            // Deliberately does NOT say "move it to /Applications": that was
            // measured to be the wrong advice, since the real cause is the
            // ad-hoc signature and the status is .notFound from there too.
            return "Unavailable: macOS will not register an ad-hoc-signed app "
                + "as a login item. Needs a real code-signing identity."
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
