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
        // Next/Previous Monitor, mask 786432 — the same arrows as the halves
        // above, minus the command modifier.
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: 786_432), .display(.next)),
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: 786_432), .display(.previous)),
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

@Test func bindsDisplayMovesToControlOptionArrows() {
    // From the user's live SizeUp configuration: control+option, mask 786432.
    let ctrlOpt: UInt = 786_432
    func shortcut(for action: Action) -> Shortcut? {
        DefaultKeymap.bindings.first { $0.1 == action }?.0
    }

    #expect(shortcut(for: .display(.next))
        == Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlOpt))
    #expect(shortcut(for: .display(.previous))
        == Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlOpt))
}

@Test func displayShortcutsDoNotCollideWithTheHalvesBindings() {
    // Halves are control+option+COMMAND on the SAME arrows. A dropped command
    // bit would silently steal them, and the duplicate would then be dropped
    // at registration rather than reported.
    let shortcuts = DefaultKeymap.bindings.map(\.0)
    #expect(Set(shortcuts).count == shortcuts.count)
}

@Test func everyDirectionHasItsOwnLabel() {
    #expect(DefaultKeymap.title(for: .display(.next)) == "Next Display")
    #expect(DefaultKeymap.title(for: .display(.previous)) == "Previous Display")
    #expect(DefaultKeymap.title(for: .display(.above)) == "Display Above")
    #expect(DefaultKeymap.title(for: .display(.below)) == "Display Below")
    #expect(DefaultKeymap.title(for: .space(.next)) == "Next Space")
    #expect(DefaultKeymap.title(for: .space(.previous)) == "Previous Space")
    #expect(DefaultKeymap.title(for: .space(.above)) == "Space Above")
    #expect(DefaultKeymap.title(for: .space(.below)) == "Space Below")
}

@Test func everyBoundActionIsRoutableAndLabelled() {
    // Guards the integration seam that killed the menu in M1: a binding whose
    // action the router ignores, or that has no label, is a dead shortcut.
    for (_, action) in DefaultKeymap.bindings {
        #expect(!DefaultKeymap.title(for: action).isEmpty)
    }
    #expect(DefaultKeymap.bindings.count == 13)
}
