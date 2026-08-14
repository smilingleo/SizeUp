import ServiceManagement

/// Registers the app itself as a login item.
///
/// `SMAppService.mainApp` needs no helper bundle and no `LaunchAgents` plist —
/// the app registers itself. It does require the app to live somewhere the
/// system is willing to launch from, `/Applications` in practice, so
/// registration can legitimately fail while running from a build directory.
/// That surfaces as a thrown error rather than a silent no-op, because a login
/// item that quietly did not register is exactly the failure the user would
/// only discover after the next reboot.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// False when the system has told us registration cannot succeed — most
    /// often because the bundle is not in a location it will launch from.
    static var isSupported: Bool {
        SMAppService.mainApp.status != .notFound
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
