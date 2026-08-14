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
