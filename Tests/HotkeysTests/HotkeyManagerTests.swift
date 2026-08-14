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
    #expect(manager.registrationFailures.map(\.shortcut) == [shortcut])
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
    #expect(manager.registrationFailures.map(\.shortcut) == [shortcut])
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

@MainActor
@Test func duplicateRegistrationIsReportedAsOurOwnConflictNotAnotherApp() {
    let manager = HotkeyManager()
    defer { manager.unregisterAll() }
    let shortcut = Shortcut(keyCode: 80, modifierFlags: 0)  // F19, unlikely to collide

    #expect(manager.register(shortcut) {})
    #expect(!manager.register(shortcut) {})

    let failure = manager.failure(for: shortcut)
    #expect(failure?.reason == .alreadyClaimedByThisApp)
    #expect(failure?.shortcut == shortcut)
    #expect(failure?.explanation == "duplicate shortcut")
}

@MainActor
@Test func handlerInstallFailureIsDistinctFromAShortcutConflict() {
    let manager = HotkeyManager()
    defer { manager.unregisterAll() }
    manager.forceEventHandlerInstallFailureForTesting = true
    let shortcut = Shortcut(keyCode: 81, modifierFlags: 0)

    #expect(!manager.register(shortcut) {})

    // A blanket "unavailable" would conflate this with a shortcut collision,
    // which has a completely different remedy.
    #expect(manager.failure(for: shortcut)?.reason == .handlerInstallFailed)
    #expect(manager.failure(for: shortcut)?.explanation == "hotkeys unavailable")
}

@MainActor
@Test func noFailureIsRecordedForAShortcutThatRegistered() {
    let manager = HotkeyManager()
    defer { manager.unregisterAll() }
    let shortcut = Shortcut(keyCode: 82, modifierFlags: 0)
    #expect(manager.register(shortcut) {})
    #expect(manager.failure(for: shortcut) == nil)
    #expect(manager.registrationFailures.isEmpty)
}
