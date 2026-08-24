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
    let newShortcut = Shortcut(keyCode: KeyCode.c, modifierFlags: 1_310_720)
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
    let collidingShortcut = Shortcut(keyCode: 99, modifierFlags: 1_835_008)

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
    let firstAttempt = Shortcut(keyCode: 1, modifierFlags: 786_432)
    let finalAttempt = Shortcut(keyCode: 2, modifierFlags: 917_504)
    let overrides = [
        ShortcutOverride(action: target, keyCode: firstAttempt.keyCode, modifierFlags: firstAttempt.modifierFlags),
        ShortcutOverride(action: target, keyCode: finalAttempt.keyCode, modifierFlags: finalAttempt.modifierFlags),
    ]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    let binding = try #require(resolved.first { $0.action == target })
    #expect(binding.shortcut == finalAttempt)
}

@Test func anOverrideForAnActionDefaultKeymapDoesNotBindIsIgnoredRatherThanAppended() {
    // `.space(.above)`/`.space(.below)` have no default binding: macOS has no
    // vertical neighbour for either to reach (see `SpaceSequence`'s doc).
    let overrides = [ShortcutOverride(action: .space(.above), keyCode: 5, modifierFlags: 6)]

    let resolved = KeymapResolver.resolve(overrides: overrides).bindings

    #expect(resolved.count == DefaultKeymap.bindings.count)
    #expect(!resolved.contains { $0.action == .space(.above) })
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

    #expect(displaced == [.snapBack])
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

    #expect(displaced.isEmpty)
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


/// `assigning` used to consult only `resolve`'s output, which merges overrides
/// into `DefaultKeymap` — so an override for an action with no default entry was
/// invisible to it and could not be displaced.
///
/// A SizeUp import creates such overrides for `space.above`/`space.below`,
/// which have no default binding because macOS has no vertical neighbour for
/// either to reach. Left in the file, one of them is a hidden second claim on
/// the key, inert only until something else binds it and `unbindLosers` kills
/// one of them without saying so. That is precisely the "presses a key that
/// will never work again" outcome the import's own alert was written to
/// prevent.
@Test func assigningDisplacesAnOverrideForAnActionThatHasNoDefaultBinding() throws {
    // F13 with all three real modifiers: nothing in DefaultKeymap uses it.
    let contested = Shortcut(keyCode: 105, modifierFlags: 1_835_008)
    let imported = [
        ShortcutOverride(
            action: .space(.above),
            keyCode: contested.keyCode,
            modifierFlags: contested.modifierFlags
        )
    ]
    #expect(!KeymapResolver.resolve(overrides: imported).bindings.contains { $0.action == .space(.above) })

    let (next, displaced) = KeymapResolver.assigning(contested, to: .center, in: imported)

    #expect(displaced == [.space(.above)])
    let spaceEntry = try #require(next.first { $0.action == .space(.above) })
    #expect(spaceEntry.keyCode == nil)
    #expect(next.filter { $0.keyCode == contested.keyCode }.count == 1)
}

/// The other half of the same defect. `resolve` unbinds the loser of a conflict,
/// so an action that HAS a default but lost one appears unbound in
/// `current.bindings` while its raw entry still claims the key. Restricting the
/// scan to actions with no default missed this: recording that key elsewhere left
/// the raw claim in place, and after the next resolve the key belonged to the
/// action the tab had been showing as unbound — so the recording appeared to do
/// nothing, and the message named the wrong victim.
@Test func assigningDisplacesARawClaimHeldByAnActionThatAlreadyLostAConflict() throws {
    let contested = Shortcut(keyCode: 77, modifierFlags: 1_835_008)
    let file = [
        ShortcutOverride(
            action: .half(.left),
            keyCode: contested.keyCode,
            modifierFlags: contested.modifierFlags
        ),
        ShortcutOverride(
            action: .half(.right),
            keyCode: contested.keyCode,
            modifierFlags: contested.modifierFlags
        ),
    ]
    // Precondition: one of them is already unbound, so it is invisible to a scan
    // of resolved bindings.
    let before = KeymapResolver.resolve(overrides: file).bindings
    #expect(before.filter { $0.shortcut == contested }.count == 1)

    let (next, displaced) = KeymapResolver.assigning(contested, to: .center, in: file)

    #expect(displaced.contains(.half(.left)))
    #expect(displaced.contains(.half(.right)))
    // And the recording actually takes effect, which is the point.
    let after = KeymapResolver.resolve(overrides: next).bindings
    let holder = try #require(after.first { $0.shortcut == contested })
    #expect(holder.action == .center)
}

/// `resolve` honours the last entry for an action, so an earlier superseded entry
/// is not a claim on anything. Treating it as one unbound a binding that never
/// conflicted with the shortcut being recorded.
@Test func assigningIgnoresASupersededOverrideThatOnlyLooksLikeAClaim() throws {
    let contested = Shortcut(keyCode: 78, modifierFlags: 1_835_008)
    let elsewhere = Shortcut(keyCode: 79, modifierFlags: 1_835_008)
    let file = [
        ShortcutOverride(
            action: .space(.next),
            keyCode: contested.keyCode,
            modifierFlags: contested.modifierFlags
        ),
        ShortcutOverride(
            action: .space(.next),
            keyCode: elsewhere.keyCode,
            modifierFlags: elsewhere.modifierFlags
        ),
    ]

    let (next, displaced) = KeymapResolver.assigning(contested, to: .center, in: file)

    #expect(displaced.isEmpty)
    let surviving = try #require(next.last { $0.action == .space(.next) })
    #expect(surviving.keyCode == elsewhere.keyCode)
}

/// Two entries for one defaultless action both matched the raw scan, so the
/// action was named twice in the sentence shown to the user.
@Test func aDisplacedActionIsNamedOnlyOnceHoweverManyEntriesClaimTheKey() {
    let contested = Shortcut(keyCode: 80, modifierFlags: 1_835_008)
    let duplicated = Array(
        repeating: ShortcutOverride(
            action: .space(.above),
            keyCode: contested.keyCode,
            modifierFlags: contested.modifierFlags
        ),
        count: 3
    )

    let (next, displaced) = KeymapResolver.assigning(contested, to: .center, in: duplicated)

    #expect(displaced == [.space(.above)])
    #expect(next.filter { $0.action == .space(.above) }.count == 1)
}

// MARK: - The capture side of the merge

@Test func bindingACaptureShortcutToAWindowActionDisplacesTheCaptureAction() throws {
    // The unified conflict detection the design promises: the resolver sees all
    // 17 actions, so a user who records ⌃⌘A (Screenshot's default) for a window
    // action does not silently kill screenshot capture — the capture action is
    // reported displaced, exactly as a window/window collision is today.
    let screenshot = try #require(
        DefaultKeymap.bindings.first { $0.1 == .captureScreenshot }?.0
    )
    let (overrides, displaced) = KeymapResolver.assigning(
        screenshot, to: .half(.left), in: []
    )

    #expect(displaced == [.captureScreenshot])
    let resolution = KeymapResolver.resolve(overrides: overrides)
    // The capture action is unbound (its default was the key we just took)…
    #expect(resolution.shortcut(for: .captureScreenshot) == nil)
    // …and the window action now holds it.
    #expect(resolution.shortcut(for: .half(.left)) == screenshot)
    #expect(resolution.conflicts.isEmpty)
}

@Test func aFullKeymapHoldsSeventeenActions() {
    // 15 window actions + 2 capture actions. The four dead SizeUp bindings
    // (display/space above/below) have no default and so add no rows; the
    // count is the stable "what does this keymap actually bind" figure.
    #expect(DefaultKeymap.bindings.count == 17)
    let resolved = KeymapResolver.resolve(overrides: [])
    #expect(resolved.bindings.count == 17)
    // Every one of the 17 is bound (none ship unbound by default).
    #expect(resolved.bindings.allSatisfy { $0.shortcut != nil })
}

@Test func restoringDefaultsRecoversAllSeventeenBindings() {
    // `restoreDefaults` writes an empty overrides list, which resolves to the
    // full default keymap — all 17, none nil. This is the round trip the
    // Shortcuts tab's "Restore Defaults" button depends on.
    let resolution = KeymapResolver.resolve(overrides: [])
    #expect(resolution.bindings.count == 17)
    #expect(resolution.bindings.allSatisfy { $0.shortcut != nil })
    for (defaultShortcut, action) in DefaultKeymap.bindings {
        #expect(resolution.shortcut(for: action) == defaultShortcut)
    }
}
