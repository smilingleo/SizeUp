import Testing
@testable import Hotkeys

/// Values taken verbatim from the user's SizeUp preferences.
/// 1835008 = control + option + command
/// 917504  = shift + control + option
/// 786432  = control + option
/// 1310720 = control + command
@Test func translatesControlOptionCommandToCarbon() {
    let s = Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: 1_835_008)
    // controlKey 0x1000 | optionKey 0x800 | cmdKey 0x100 = 6400
    #expect(s.carbonModifiers == 6400)
}

@Test func translatesShiftControlOptionToCarbon() {
    let s = Shortcut(keyCode: KeyCode.upArrow, modifierFlags: 917_504)
    // shiftKey 0x200 | controlKey 0x1000 | optionKey 0x800 = 6656
    #expect(s.carbonModifiers == 6656)
}

@Test func translatesControlOptionToCarbon() {
    let s = Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: 786_432)
    // controlKey 0x1000 | optionKey 0x800 = 6144
    #expect(s.carbonModifiers == 6144)
}

@Test func translatesControlCommandToCarbon() {
    let s = Shortcut(keyCode: KeyCode.downArrow, modifierFlags: 1_310_720)
    // controlKey 0x1000 | cmdKey 0x100 = 4352
    #expect(s.carbonModifiers == 4352)
}

@Test func ignoresNonModifierBitsSuchAsCapsLockAndFunction() {
    // 1835008 plus capsLock (65536) and function (8388608) must translate
    // identically: those bits are not part of a registered hotkey.
    let s = Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: 1_835_008 | 65_536 | 8_388_608)
    #expect(s.carbonModifiers == 6400)
}

@Test func keyCodesMatchTheUsersConfiguration() {
    #expect(KeyCode.leftArrow == 123)
    #expect(KeyCode.rightArrow == 124)
    #expect(KeyCode.downArrow == 125)
    #expect(KeyCode.upArrow == 126)
    // Verified against Carbon Events.h: kVK_ANSI_M = 0x2E, kVK_ANSI_Slash = 0x2C.
    #expect(KeyCode.m == 46)
    #expect(KeyCode.c == 8)
    #expect(KeyCode.slash == 44)
}

@Test func displayStringOrdersModifiersLikeMacOS() {
    let s = Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: 1_835_008)
    #expect(s.displayString == "⌃⌥⌘←")
}

@Test func displayStringHandlesLetterAndPunctuationKeys() {
    #expect(Shortcut(keyCode: KeyCode.m, modifierFlags: 1_835_008).displayString == "⌃⌥⌘M")
    #expect(Shortcut(keyCode: KeyCode.slash, modifierFlags: 1_835_008).displayString == "⌃⌥⌘/")
}
