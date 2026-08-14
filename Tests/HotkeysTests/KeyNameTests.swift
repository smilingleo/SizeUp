import Testing
import Carbon.HIToolbox
@testable import Hotkeys

/// `UCKeyTranslate` returns control characters for these, so they must come
/// from the static table rather than the layout lookup. Each assertion here
/// pins one table entry; a missing or misspelled entry falls through to
/// `translate`, which for most of these codes returns nil, so the test would
/// fail with `"Key N"` instead of the expected label.
@Test func arrowKeysReadAsArrowGlyphs() {
    #expect(KeyName.of(UInt32(kVK_LeftArrow)) == "←")
    #expect(KeyName.of(UInt32(kVK_RightArrow)) == "→")
    #expect(KeyName.of(UInt32(kVK_DownArrow)) == "↓")
    #expect(KeyName.of(UInt32(kVK_UpArrow)) == "↑")
}

@Test func editingAndNavigationKeysReadAsWords() {
    #expect(KeyName.of(UInt32(kVK_Return)) == "Return")
    #expect(KeyName.of(UInt32(kVK_Tab)) == "Tab")
    #expect(KeyName.of(UInt32(kVK_Space)) == "Space")
    #expect(KeyName.of(UInt32(kVK_Delete)) == "Delete")
    #expect(KeyName.of(UInt32(kVK_Escape)) == "Escape")
    #expect(KeyName.of(UInt32(kVK_ForwardDelete)) == "Forward Delete")
    #expect(KeyName.of(UInt32(kVK_Home)) == "Home")
    #expect(KeyName.of(UInt32(kVK_End)) == "End")
    #expect(KeyName.of(UInt32(kVK_PageUp)) == "Page Up")
    #expect(KeyName.of(UInt32(kVK_PageDown)) == "Page Down")
}

@Test func functionKeysReadAsFOneThroughFTwelve() {
    #expect(KeyName.of(UInt32(kVK_F1)) == "F1")
    #expect(KeyName.of(UInt32(kVK_F2)) == "F2")
    #expect(KeyName.of(UInt32(kVK_F3)) == "F3")
    #expect(KeyName.of(UInt32(kVK_F4)) == "F4")
    #expect(KeyName.of(UInt32(kVK_F5)) == "F5")
    #expect(KeyName.of(UInt32(kVK_F6)) == "F6")
    #expect(KeyName.of(UInt32(kVK_F7)) == "F7")
    #expect(KeyName.of(UInt32(kVK_F8)) == "F8")
    #expect(KeyName.of(UInt32(kVK_F9)) == "F9")
    #expect(KeyName.of(UInt32(kVK_F10)) == "F10")
    #expect(KeyName.of(UInt32(kVK_F11)) == "F11")
    #expect(KeyName.of(UInt32(kVK_F12)) == "F12")
}

@Test func keypadDigitsAndOperatorsReadAsKeypadPrefixedLabels() {
    #expect(KeyName.of(UInt32(kVK_ANSI_Keypad0)) == "Keypad 0")
    #expect(KeyName.of(UInt32(kVK_ANSI_Keypad9)) == "Keypad 9")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadDecimal)) == "Keypad .")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadMultiply)) == "Keypad *")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadPlus)) == "Keypad +")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadClear)) == "Keypad Clear")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadDivide)) == "Keypad /")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadEnter)) == "Keypad Enter")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadMinus)) == "Keypad -")
    #expect(KeyName.of(UInt32(kVK_ANSI_KeypadEquals)) == "Keypad =")
}

/// `kVK_ANSI_A` is not in the static table, so this exercises the
/// `UCKeyTranslate` path against whatever layout the test machine has. Every
/// Latin layout maps this physical position to a single Latin letter, which
/// is the one thing the plan says is safe to assert about a live layout.
@Test func aLetterKeyYieldsOneUppercaseLatinCharacter() {
    let name = KeyName.of(UInt32(kVK_ANSI_A))
    #expect(name.count == 1)
    #expect(name == name.uppercased())
    #expect(("A"..."Z").contains(name))
}

/// Nothing on a real keyboard reaches this code, so `translate` must fail
/// and fall through to the last resort. `"Key N"` — never `"?"`, which the
/// plan calls out by name as indistinguishable from a real `?` key.
@Test func anAbsurdKeyCodeYieldsTheKeyNFormNotAQuestionMark() {
    #expect(KeyName.of(9999) == "Key 9999")
}

/// Pins the exact strings the shipped defaults must continue to display,
/// independent of any refactor to how `keyName` is produced internally.
@Test func displayStringForShippedDefaultsReadsExactlyAsBefore() {
    #expect(Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: 1_835_008).displayString == "⌃⌥⌘←")
    #expect(Shortcut(keyCode: KeyCode.m, modifierFlags: 1_835_008).displayString == "⌃⌥⌘M")
    #expect(Shortcut(keyCode: KeyCode.slash, modifierFlags: 1_835_008).displayString == "⌃⌥⌘/")
    #expect(Shortcut(keyCode: KeyCode.upArrow, modifierFlags: 917_504).displayString == "⌃⌥⇧↑")
    #expect(Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: 786_432).displayString == "⌃⌥→")
}
