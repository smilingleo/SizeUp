import Testing
import Geometry
import Hotkeys
@testable import Core

/// `KeymapResolver` merges `ShortcutOverride`s over `DefaultKeymap.bindings`.
/// Every assertion here reads the defaults out of `DefaultKeymap` itself —
/// this project has twice shipped tests that compared local literals to each
/// other, and once one that compared a literal to a framework constant
/// without ever reading the code under test. All three were caught only by
/// mutation testing.

@Test func noOverridesReproducesDefaultKeymapExactly() {
    let resolved = KeymapResolver.resolve(overrides: []).bindings

    #expect(resolved.count == DefaultKeymap.bindings.count)
    for (binding, (defaultShortcut, action)) in zip(resolved, DefaultKeymap.bindings) {
        #expect(binding.action == action)
        #expect(binding.shortcut == defaultShortcut)
    }
}

@Test func oneOverrideChangesOnlyItsOwnBindingAndLeavesEveryOtherActionAtItsDefault() throws {
    let target = try #require(DefaultKeymap.bindings.first { $0.1 == .fullScreen }).1
    let newShortcut = Shortcut(keyCode: KeyCode.c, modifierFlags: 0)
    let overrides = [ShortcutOverride(action: target, keyCode: newShortcut.keyCode, modifierFlags: newShortcut.modifierFlags)]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    #expect(resolved.count == DefaultKeymap.bindings.count)
    for (binding, (defaultShortcut, action)) in zip(resolved, DefaultKeymap.bindings) {
        #expect(binding.action == action)
        if action == target {
            #expect(binding.shortcut == newShortcut)
        } else {
            #expect(binding.shortcut == defaultShortcut)
        }
    }
}

@Test func unbindingOneActionYieldsANilShortcutAndLeavesEveryOtherActionBound() throws {
    let target = try #require(DefaultKeymap.bindings.first { $0.1 == .snapBack }).1
    let overrides = [ShortcutOverride(action: target, keyCode: nil, modifierFlags: 0)]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    #expect(resolved.count == DefaultKeymap.bindings.count)
    for (binding, (defaultShortcut, action)) in zip(resolved, DefaultKeymap.bindings) {
        #expect(binding.action == action)
        if action == target {
            #expect(binding.shortcut == nil)
        } else {
            #expect(binding.shortcut == defaultShortcut)
        }
    }
}

@Test func aHandEditedConflictLeavesExactlyOneActionHoldingTheKeyAndReportsBothClaimants() throws {
    // Two different DefaultKeymap actions, hand-pointed at the same new
    // shortcut — not something the recorder UI would ever produce, but a
    // settings file can be edited by hand.
    let (_, firstAction) = DefaultKeymap.bindings[0]
    let (_, secondAction) = DefaultKeymap.bindings[1]
    let collidingShortcut = Shortcut(keyCode: 99, modifierFlags: 42)

    let overrides = [
        ShortcutOverride(action: firstAction, keyCode: collidingShortcut.keyCode, modifierFlags: collidingShortcut.modifierFlags),
        ShortcutOverride(action: secondAction, keyCode: collidingShortcut.keyCode, modifierFlags: collidingShortcut.modifierFlags),
    ]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    // DefaultKeymap order decides the winner: the earlier action keeps the
    // shortcut, the later one is unbound rather than dropped from the list.
    let firstBinding = try #require(resolved.first { $0.action == firstAction })
    let secondBinding = try #require(resolved.first { $0.action == secondAction })
    #expect(firstBinding.shortcut == collidingShortcut)
    #expect(secondBinding.shortcut == nil)
    #expect(resolved.filter { $0.shortcut == collidingShortcut }.count == 1)

    // `conflicts(in:)` is what the file actually asked for, before `resolve`
    // corrects it — it is what the UI would show as "you asked for two
    // actions on this key". Reconstructed by hand here since `resolve`'s own
    // output has already unbound the loser and no longer carries the
    // collision.
    let asked = [
        ResolvedBinding(action: firstAction, shortcut: collidingShortcut),
        ResolvedBinding(action: secondAction, shortcut: collidingShortcut),
    ]
    let conflicts = KeymapResolver.conflicts(in: asked)
    #expect(conflicts.count == 1)
    let claimants = try #require(conflicts[collidingShortcut])
    #expect(claimants.count == 2)
    #expect(claimants.contains(firstAction))
    #expect(claimants.contains(secondAction))
}

@Test func aLaterOverrideForTheSameActionWinsOverAnEarlierOne() throws {
    let target = try #require(DefaultKeymap.bindings.first { $0.1 == .center }).1
    let firstAttempt = Shortcut(keyCode: 1, modifierFlags: 100)
    let finalAttempt = Shortcut(keyCode: 2, modifierFlags: 200)
    let overrides = [
        ShortcutOverride(action: target, keyCode: firstAttempt.keyCode, modifierFlags: firstAttempt.modifierFlags),
        ShortcutOverride(action: target, keyCode: finalAttempt.keyCode, modifierFlags: finalAttempt.modifierFlags),
    ]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    let binding = try #require(resolved.first { $0.action == target })
    #expect(binding.shortcut == finalAttempt)
}

@Test func anOverrideForAnActionDefaultKeymapDoesNotBindIsIgnoredRatherThanAppended() {
    // .space actions have no default binding yet (they arrive in M5).
    let overrides = [ShortcutOverride(action: .space(.next), keyCode: 5, modifierFlags: 6)]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    #expect(resolved.count == DefaultKeymap.bindings.count)
    #expect(!resolved.contains { $0.action == .space(.next) })
    for (binding, (defaultShortcut, action)) in zip(resolved, DefaultKeymap.bindings) {
        #expect(binding.action == action)
        #expect(binding.shortcut == defaultShortcut)
    }
}

@Test func conflictsIgnoresUnboundActionsSinceThereIsNoSharedShortcutToReport() {
    let bindings = [
        ResolvedBinding(action: .center, shortcut: nil),
        ResolvedBinding(action: .snapBack, shortcut: nil),
    ]

    #expect(KeymapResolver.conflicts(in: bindings).isEmpty)
}

// MARK: - Resolution carries the conflict evidence that bindings destroys

@Test func aConflictIsReportedEvenThoughTheBindingsAreLeftRegistrable() throws {
    // The reason `resolve` returns both halves. `bindings` has already unbound
    // the loser so the keymap can be registered, and that erases the collision;
    // asking `conflicts(in:)` about the corrected list can only ever say "none".
    let half = try #require(
        DefaultKeymap.bindings.first { $0.1 == .half(.left) }?.0
    )
    let resolution = KeymapResolver.resolve(overrides: [
        ShortcutOverride(action: .center, keyCode: half.keyCode, modifierFlags: half.modifierFlags)
    ])

    let holders = try #require(resolution.conflicts[half])
    #expect(Set(holders.map(\.description)) == Set([Action.half(.left), .center].map(\.description)))

    let stillBound = resolution.bindings.filter { $0.shortcut == half }
    #expect(stillBound.count == 1)
    // And the corrected list genuinely reports nothing, which is why the
    // evidence had to be carried out of the same call.
    #expect(KeymapResolver.conflicts(in: resolution.bindings).isEmpty)
}

@Test func recordingAShortcutTakesItFromWhicheverActionHeldIt() throws {
    let snapBack = try #require(
        DefaultKeymap.bindings.first { $0.1 == .snapBack }?.0
    )
    let (overrides, displaced) = KeymapResolver.assigning(snapBack, to: .center, in: [])

    #expect(displaced == .snapBack)
    let resolution = KeymapResolver.resolve(overrides: overrides)
    #expect(resolution.shortcut(for: .center) == snapBack)
    // Unbound, not left to collide, and not merely reverted to its default --
    // its default IS the shortcut we just took.
    #expect(resolution.shortcut(for: .snapBack) == nil)
    #expect(resolution.conflicts.isEmpty)
}

@Test func recordingAnUnusedShortcutDisplacesNothing() {
    // F13 with all three real modifiers: nothing in DefaultKeymap uses it.
    let free = Shortcut(keyCode: 105, modifierFlags: 1_835_008)
    let (overrides, displaced) = KeymapResolver.assigning(free, to: .center, in: [])

    #expect(displaced == nil)
    let resolution = KeymapResolver.resolve(overrides: overrides)
    #expect(resolution.shortcut(for: .center) == free)
    // Every other action keeps exactly what it had.
    for (shortcut, action) in DefaultKeymap.bindings where action != .center {
        #expect(resolution.shortcut(for: action) == shortcut)
    }
}

@Test func rerecordingTheSameActionDoesNotAccumulateOverrides() {
    // The override list is persisted, so an append-only recorder would grow the
    // settings file without bound as the user tried shortcuts out.
    var overrides: [ShortcutOverride] = []
    for code in [UInt32(105), 106, 107] {
        overrides = KeymapResolver.assigning(
            Shortcut(keyCode: code, modifierFlags: 1_835_008), to: .center, in: overrides
        ).overrides
    }
    #expect(overrides.filter { $0.action == .center }.count == 1)
    #expect(KeymapResolver.resolve(overrides: overrides).shortcut(for: .center)?.keyCode == 107)
}


// Action is Equatable but not CustomStringConvertible; the conflict assertion
// above needs an order-independent comparison and Action is not Hashable.
extension Action {
    var description: String { String(reflecting: self) }
}
