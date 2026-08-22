import AppKit
import Testing
import Geometry
import Hotkeys
@testable import Core

/// These are the user's actual SizeUp shortcuts. Getting any of them wrong
/// breaks muscle memory built over 13,318 window moves.
@Test func matchesTheUsersSizeUpConfiguration() {
    let ctrlOptCmd: UInt = 1_835_008
    let ctrlOptShift: UInt = 917_504
    // From the author's live SizeUp plist: ComboFlags 1310720, Carbon 4352.
    let ctrlCmd: UInt = 1_310_720

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
        // Next/Previous Space.
        (Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: ctrlCmd), .space(.next)),
        (Shortcut(keyCode: KeyCode.leftArrow, modifierFlags: ctrlCmd), .space(.previous)),
    ]

    // The capture actions were merged into this keymap (C1) and sit ahead of
    // the window bindings, so compare the window bindings as a set, not the
    // whole list: the user's SizeUp configuration must all be present and
    // intact, regardless of where the capture entries were placed.
    // The three capture actions are the only ones the capture merge added;
    // everything else is the original window keymap.
    let captureActions: [Action] = [.captureScreenshot, .startRecording, .toggleScrollCapture]
    let windowBindings = DefaultKeymap.bindings.filter { !captureActions.contains($0.1) }
    #expect(windowBindings.count == expected.count)
    for (want, got) in zip(expected, windowBindings) {
        #expect(want.0 == got.0)
        #expect(want.1 == got.1)
    }
    #expect(DefaultKeymap.bindings.count == expected.count + 3) // + the three capture actions
}

@Test func allShortcutsAreUnique() {
    let shortcuts = DefaultKeymap.bindings.map(\.0)
    #expect(Set(shortcuts).count == shortcuts.count)
}

@Test func theThreeCaptureDefaultsMatchClipShot() {
    // The standalone ClipShot defaults, verbatim: control+command (1_310_720,
    // the same mask as the Space moves) over A / Z / S. These are the
    // user-facing capture shortcuts, so the test pins the exact values rather
    // than re-deriving them from the (possibly edited) keymap.
    let ctrlCmd: UInt = 1_310_720
    func shortcut(for action: Action) -> Shortcut? {
        DefaultKeymap.bindings.first { $0.1 == action }?.0
    }

    #expect(shortcut(for: .captureScreenshot)
        == Shortcut(keyCode: 0, modifierFlags: ctrlCmd))   // A
    #expect(shortcut(for: .startRecording)
        == Shortcut(keyCode: 6, modifierFlags: ctrlCmd))   // Z
    #expect(shortcut(for: .toggleScrollCapture)
        == Shortcut(keyCode: 1, modifierFlags: ctrlCmd))   // S
}

@Test func theCaptureActionsHaveDistinctLabels() {
    #expect(DefaultKeymap.title(for: .captureScreenshot) == "Screenshot")
    #expect(DefaultKeymap.title(for: .startRecording) == "Record Screen")
    #expect(DefaultKeymap.title(for: .toggleScrollCapture) == "Scroll Capture")
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

@Test func displayShortcutsDifferFromTheHalvesByExactlyTheCommandBit() throws {
    // Reads the masks OUT of DefaultKeymap. Asserting a relation among local
    // literals would pass no matter what the keymap actually contained.
    func mask(for action: Action) throws -> UInt {
        try #require(DefaultKeymap.bindings.first { $0.1 == action }?.0).modifierFlags
    }

    let halfRight = try mask(for: .half(.right))
    let displayNext = try mask(for: .display(.next))
    let command = UInt(NSEvent.ModifierFlags.command.rawValue)

    // Same arrow key, so the command bit is the only thing separating them.
    #expect(halfRight == displayNext | command)
    #expect(displayNext & command == 0)

    // And the distinction must survive translation to Carbon, since that is
    // what registration actually uses.
    let a = Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: halfRight)
    let b = Shortcut(keyCode: KeyCode.rightArrow, modifierFlags: displayNext)
    #expect(a.carbonModifiers != b.carbonModifiers)
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

@Test func everyBoundActionIsDistinctAndCarriesADistinctLabel() {
    // Guards the integration seam that killed the menu in M1. The real risk is
    // not an empty label (every arm returns a literal, so that cannot fail) but
    // two bindings mapping to the same action, or two actions sharing a label
    // so the menu shows the same row twice.
    let actions = DefaultKeymap.bindings.map(\.1)
    let labels = actions.map { DefaultKeymap.title(for: $0) }

    // Labels are a pure function of actions, so distinct labels implies
    // distinct actions; both are asserted because a future `title(for:)` that
    // returned the same string for two actions should fail here, loudly.
    #expect(Set(labels).count == labels.count)
}
