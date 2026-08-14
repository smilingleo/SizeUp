import Testing
@testable import Hotkeys

@MainActor
@Test func registersAShortcutSuccessfully() {
    let manager = HotkeyManager()
    defer { manager.unregisterAll() }
    // F19 with no modifiers: an unlikely conflict on any real system.
    let ok = manager.register(Shortcut(keyCode: 80, modifierFlags: 0)) {}
    #expect(ok)
    #expect(manager.registrationFailures.isEmpty)
}

@MainActor
@Test func reportsFailureWhenSameShortcutRegisteredTwice() {
    let manager = HotkeyManager()
    defer { manager.unregisterAll() }
    let shortcut = Shortcut(keyCode: 80, modifierFlags: 0)
    #expect(manager.register(shortcut) {})
    let second = manager.register(shortcut) {}
    #expect(!second)
    #expect(manager.registrationFailures == [shortcut])
}

@MainActor
@Test func unregisterAllClearsStateAndAllowsReregistration() {
    let manager = HotkeyManager()
    let shortcut = Shortcut(keyCode: 80, modifierFlags: 0)
    #expect(manager.register(shortcut) {})
    manager.unregisterAll()
    #expect(manager.registrationFailures.isEmpty)
    #expect(manager.register(shortcut) {})
    manager.unregisterAll()
}

@MainActor
@Test func failedEventHandlerInstallReportsFailureRatherThanSuccess() {
    let manager = HotkeyManager()
    defer { manager.unregisterAll() }
    manager.forceEventHandlerInstallFailureForTesting = true
    let shortcut = Shortcut(keyCode: 80, modifierFlags: 0)
    let ok = manager.register(shortcut) {}
    #expect(!ok)
    #expect(manager.registrationFailures == [shortcut])
    #expect(manager.handlerInstallFailed)
}

@MainActor
@Test func unregisterAllClearsHandlerInstallFailedFlag() {
    let manager = HotkeyManager()
    manager.forceEventHandlerInstallFailureForTesting = true
    let shortcut = Shortcut(keyCode: 80, modifierFlags: 0)
    _ = manager.register(shortcut) {}
    #expect(manager.handlerInstallFailed)
    manager.unregisterAll()
    #expect(!manager.handlerInstallFailed)
}

@MainActor
@Test func deallocatingManagerWithoutUnregisterAllStillReleasesTheShortcut() {
    let shortcut = Shortcut(keyCode: 80, modifierFlags: 0)

    do {
        let manager = HotkeyManager()
        #expect(manager.register(shortcut) {})
        // No `unregisterAll()` call here: `manager` goes out of scope and is
        // deallocated, relying entirely on ARC-driven teardown.
    }

    // If the first registration were still claimed system-wide, this second
    // registration on a fresh manager would fail.
    let secondManager = HotkeyManager()
    defer { secondManager.unregisterAll() }
    #expect(secondManager.register(shortcut) {})
}
