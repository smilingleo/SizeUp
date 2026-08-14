import AppKit
import Testing
import Foundation
@testable import Config
@testable import Geometry

/// Every action must round-trip through its string identifier, or a rebind
/// stored under one spelling would come back as a different action (or none)
/// after the app is rebuilt with a slightly different enum layout — the
/// exact failure mode a stable string table exists to prevent.
@Test func everyActionRoundTripsThroughItsIdentifier() {
    let actions: [Action] = [
        .half(.left), .half(.right), .half(.top), .half(.bottom),
        .quarter(.upperLeft), .quarter(.upperRight), .quarter(.lowerLeft), .quarter(.lowerRight),
        .center, .fullScreen, .snapBack,
        .display(.next), .display(.previous), .display(.above), .display(.below),
        .space(.next), .space(.previous), .space(.above), .space(.below),
    ]
    for action in actions {
        let identifier = ActionIdentifier.identifier(for: action)
        #expect(ActionIdentifier.action(for: identifier) == action)
    }
}

@Test func anUnknownActionIdentifierResolvesToNilRatherThanThrowing() {
    #expect(ActionIdentifier.action(for: "half.upsideDown") == nil)
}

@Test func aShiftOnlyBindingResolvesToNil() {
    let shiftOnly: UInt = 1 << 17
    let setting = ShortcutSetting(action: "half.left", keyCode: 123, modifierFlags: shiftOnly)
    #expect(setting.resolved == nil)
}

@Test func aBareKeycodeWithNoModifierResolvesToNil() {
    let setting = ShortcutSetting(action: "half.left", keyCode: 123, modifierFlags: 0)
    #expect(setting.resolved == nil)
}

/// The distinction the whole unbind feature rests on: an entry that carries
/// `keyCode: nil` is a deliberate unbind, not a malformed binding, and must
/// resolve successfully rather than being rejected by the modifier check
/// that guards real bindings.
@Test func anUnbindEntryResolvesSuccessfullyWithANilKeyCode() {
    let setting = ShortcutSetting(action: "half.left", keyCode: nil, modifierFlags: 0)
    let resolved = setting.resolved
    #expect(resolved?.action == .half(.left))
    #expect(resolved?.keyCode == nil)
}

@Test func aValidControlOptionCommandBindingResolves() {
    let ctrlOptCmd: UInt = 1_835_008
    let setting = ShortcutSetting(action: "fullScreen", keyCode: 46, modifierFlags: ctrlOptCmd)
    let resolved = setting.resolved
    #expect(resolved?.action == .fullScreen)
    #expect(resolved?.keyCode == 46)
    #expect(resolved?.modifierFlags == ctrlOptCmd)
}

@Test func anUnknownIdentifierWithAValidModifierStillResolvesToNil() {
    let ctrlOptCmd: UInt = 1_835_008
    let setting = ShortcutSetting(action: "half.diagonal", keyCode: 46, modifierFlags: ctrlOptCmd)
    #expect(setting.resolved == nil)
}

@Test func defaultSettingsHaveNoShortcutOverrides() {
    #expect(Settings().shortcutOverrides == [])
}

@Test func aSettingsFileContainingOverridesDecodes() throws {
    let json = """
    {"shortcutOverrides": [{"action": "half.left", "keyCode": 123, "modifierFlags": 1835008}]}
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.shortcutOverrides == [
        ShortcutSetting(action: "half.left", keyCode: 123, modifierFlags: 1_835_008)
    ])
}

// Config deliberately cannot import AppKit, so it reproduces three NSEvent
// modifier bits as literals. That duplication is only safe if something checks
// it, and nothing in Config can: a wrong literal would silently accept a
// shortcut with no real modifier, or reject a valid one, and every test written
// with the same literals would agree with the bug. This test lives here because
// a TEST may import AppKit even though the module under test may not.
@Test func theDuplicatedModifierBitsAgreeWithAppKit() {
    // Reading Config's OWN constants, not re-stating the literals. The first
    // version of this test compared `1 << 18` to NSEvent and never touched
    // Config at all, so changing Config's control bit to `1 << 16` left it
    // green — the precise defect it was written to prevent.
    #expect(ActionIdentifier.control == NSEvent.ModifierFlags.control.rawValue)
    #expect(ActionIdentifier.option == NSEvent.ModifierFlags.option.rawValue)
    #expect(ActionIdentifier.command == NSEvent.ModifierFlags.command.rawValue)
    // Shift must NOT be in the accepted set: a shortcut of Shift+A steals a
    // capital letter from the whole system.
    #expect(ShortcutSetting(action: "center", keyCode: 8, modifierFlags: NSEvent.ModifierFlags.shift.rawValue).resolved == nil)

    // And the mask the user's own SizeUp config actually stores must pass.
    let real = ShortcutSetting(action: "center", keyCode: 8, modifierFlags: 1_835_008)
    #expect(real.resolved != nil)
    #expect(NSEvent.ModifierFlags(rawValue: 1_835_008)
        .isSuperset(of: [.control, .option, .command]))
}
