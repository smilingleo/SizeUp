import Testing
import Geometry
import Hotkeys
@testable import Core

/// These are the user's actual SizeUp shortcuts. Getting any of them wrong
/// breaks muscle memory built over 13,318 window moves.
@Test func matchesTheUsersSizeUpConfiguration() {
    let ctrlOptCmd: UInt = 1_835_008
    let ctrlOptShift: UInt = 917_504

    let expected: [(Shortcut, Action)] = [
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlOptCmd), .half(.left)),
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlOptCmd), .half(.right)),
        (Shortcut(keyCode: KeyCode.upArrow, modifierFlags: ctrlOptCmd), .half(.top)),
        (Shortcut(keyCode: KeyCode.downArrow, modifierFlags: ctrlOptCmd), .half(.bottom)),
        (Shortcut(keyCode: KeyCode.m, modifierFlags: ctrlOptCmd), .fullScreen),
        (Shortcut(keyCode: KeyCode.c, modifierFlags: ctrlOptCmd), .center),
        (Shortcut(keyCode: KeyCode.slash, modifierFlags: ctrlOptCmd), .snapBack),
        // SizeUp's default quarter arrows are clockwise from left, not spatial.
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlOptShift), .quarter(.upperLeft)),
        (Shortcut(keyCode: KeyCode.upArrow, modifierFlags: ctrlOptShift), .quarter(.upperRight)),
        (Shortcut(keyCode: KeyCode.downArrow, modifierFlags: ctrlOptShift), .quarter(.lowerLeft)),
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlOptShift), .quarter(.lowerRight)),
    ]

    #expect(DefaultKeymap.bindings.count == expected.count)
    for (want, got) in zip(expected, DefaultKeymap.bindings) {
        #expect(want.0 == got.0)
        #expect(want.1 == got.1)
    }
}

@Test func allShortcutsAreUnique() {
    let shortcuts = DefaultKeymap.bindings.map(\.0)
    #expect(Set(shortcuts).count == shortcuts.count)
}
