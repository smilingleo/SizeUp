import ServiceManagement

/// Registers the app itself as a login item.
///
/// `SMAppService.mainApp` needs no helper bundle and no `LaunchAgents` plist —
/// the app registers itself. It does require the app to live somewhere the
/// system is willing to launch from, `/Applications` in practice, so
/// registration can legitimately fail while running from a build directory.
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
        /// The system will not launch this bundle from where it currently is.
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
            return "Approve Sizeup2 in System Settings → General → Login Items."
        case .unsupported:
            return "Move Sizeup2 to /Applications to enable this."
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
