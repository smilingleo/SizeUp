import Foundation
import Testing
@testable import Config

// `ComboParser` is the pure string→(keyCode, modifiers) logic the ClipShot
// importer depends on, so it is tested directly. The US-layout key codes it
// carries are asserted against the vkeys the capture defaults need (A/Z/S),
// pinning them rather than trusting the table.

@Test func aCaptureDefaultComboParsesToTheExpectedKeys() {
    // Ctrl+Cmd+A: vkey 0, control|command.
    let a = ComboParser.parse("Ctrl+Cmd+A")
    #expect(a?.keyCode == 0)
    #expect(a?.modifierFlags == (1 << 18) | (1 << 20))
}

@Test func aRecordDefaultComboParses() {
    // Ctrl+Cmd+Z: vkey 6.
    let z = ComboParser.parse("Ctrl+Cmd+Z")
    #expect(z?.keyCode == 6)
    #expect(z?.modifierFlags == (1 << 18) | (1 << 20))
}

@Test func aScrollDefaultComboParses() {
    // Ctrl+Cmd+S: vkey 1.
    let s = ComboParser.parse("Ctrl+Cmd+S")
    #expect(s?.keyCode == 1)
    #expect(s?.modifierFlags == (1 << 18) | (1 << 20))
}

@Test func modifierSpellingsAreSynonymous() {
    #expect(ComboParser.parse("Ctrl+Cmd+A") == ComboParser.parse("control+command+a"))
    #expect(ComboParser.parse("Cmd+Shift+Left")?.keyCode == 123)
    #expect(ComboParser.parse("Cmd+Shift+Right")?.keyCode == 124)
}

@Test func altMapsToOption() {
    let alt = ComboParser.parse("Alt+Cmd+Q")
    #expect(alt?.keyCode == 12)
    #expect(alt?.modifierFlags == (1 << 19) | (1 << 20))
}

@Test func aDigitAndPunctuationKeyResolveToTheirCodes() {
    #expect(ComboParser.parse("Cmd+5")?.keyCode == 23)
    #expect(ComboParser.parse("Cmd+Slash")?.keyCode == 44)
    #expect(ComboParser.parse("Cmd+Period")?.keyCode == 47)
    #expect(ComboParser.parse("Cmd+Escape")?.keyCode == 53)
}

@Test func anUnrecognizedKeyFailsToParse() {
    // A key with no US-layout name must not resolve to a wrong code.
    #expect(ComboParser.parse("Cmd+ü") == nil)
    #expect(ComboParser.parse("Cmd+") == nil)
}

@Test func twoKeysIsNotAHotkey() {
    // "A+B" has no single key to bind.
    #expect(ComboParser.parse("Cmd+A+B") == nil)
    // No key at all (modifiers only) is likewise not a binding.
    #expect(ComboParser.parse("Ctrl+Cmd") == nil)
}

@Test func aModifierLessComboParsesButHasNoRealModifier() {
    // The parse itself succeeds — the *presence of a real modifier* is the
    // caller's judgment, the same rule `ActionIdentifier` applies to a
    // hand-edited binding. This is documented in the importer and the recorder.
    let bare = ComboParser.parse("A")
    #expect(bare?.keyCode == 0)
    #expect(bare?.modifierFlags == 0)
    #expect(ComboParser.parse("Shift+A")?.modifierFlags == (1 << 16))
}
