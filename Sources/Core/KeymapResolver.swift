import Geometry
import Hotkeys

/// A user's override for one action's shortcut.
///
/// `Core`-local, not `Config`'s `ShortcutSetting` — `Core` must not import
/// `Config` (settings persistence has no business in the domain layer), so
/// `App` performs the trivial DTO translation between the two. See
/// `ShortcutSetting.resolved`, which produces the same three fields.
///
/// `keyCode: nil` means deliberately unbound, exactly as in `ShortcutSetting`:
/// distinct from the action not appearing in the overrides list at all, which
/// leaves whatever `DefaultKeymap` ships untouched.
public struct ShortcutOverride: Equatable, Sendable {
    public let action: Action
    public let keyCode: UInt32?
    public let modifierFlags: UInt

    public init(action: Action, keyCode: UInt32?, modifierFlags: UInt) {
        self.action = action
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}

/// One action's shortcut after overrides have been merged over the defaults.
///
/// `shortcut: nil` covers two cases that must both reach the UI and the
/// registrar the same way: the action was explicitly unbound, or it lost a
/// hand-edited conflict to an action earlier in `DefaultKeymap` order. Either
/// way there is nothing to register and nothing to display but "unbound".
public struct ResolvedBinding: Equatable, Sendable {
    public let action: Action
    public let shortcut: Shortcut?

    public init(action: Action, shortcut: Shortcut?) {
        self.action = action
        self.shortcut = shortcut
    }
}

/// Merges `Settings.shortcutOverrides` (by way of `ShortcutOverride`) over
/// `DefaultKeymap.bindings`, and finds conflicts in the result.
///
/// This is where the merge lives, not in `App`: `Core` cannot depend on
/// `Config`, and `Config` cannot depend on `Hotkeys`, so nothing else is in a
/// position to combine an override with a `Shortcut`. `App`'s job is only the
/// boundary translation from `ShortcutSetting` to `ShortcutOverride`.
/// A resolved keymap, together with what the settings file asked for.
///
/// Both halves are returned from one call because they cannot be recovered from
/// each other. `bindings` has already had conflict losers unbound so that it is
/// always registrable, which destroys the evidence that a conflict existed —
/// calling `conflicts(in:)` on it can never report anything, since a nil
/// shortcut cannot collide. The plan originally declared these as two separate
/// entry points and was simply wrong about how they compose; the caller would
/// have had to rebuild the pre-deduplication list to say anything useful to the
/// user.
public struct Resolution: Equatable, Sendable {
    /// Always registrable: every shortcut is held by at most one action.
    public let bindings: [ResolvedBinding]
    /// Shortcuts the file asked two or more actions to share, before losers
    /// were unbound. Empty for anything the recorder produced.
    public let conflicts: [Shortcut: [Action]]

    public func shortcut(for action: Action) -> Shortcut? {
        bindings.first { $0.action == action }?.shortcut
    }
}

public enum KeymapResolver {
    /// Applies `overrides` to `DefaultKeymap.bindings`.
    ///
    /// Every action in `DefaultKeymap` appears exactly once, in
    /// `DefaultKeymap` order, whether or not it has an override and whether
    /// or not the result leaves it bound. An override for an action
    /// `DefaultKeymap` does not bind (a future milestone's action, or a
    /// typo'd identifier that already failed to resolve in `Config`) has no
    /// slot to land in here and is silently ignored, not appended — the
    /// output's shape is `DefaultKeymap`'s, not the overrides file's.
    ///
    /// If two overrides name the same action, the later one wins, matching
    /// last-write-wins for everything else about this file. If, after
    /// overrides are applied, two actions end up wanting the same shortcut —
    /// only possible by hand-editing the settings file, since the UI's
    /// recorder is expected to prevent it — the action earlier in
    /// `DefaultKeymap` order keeps it and the rest are unbound, so the
    /// result is always registrable with `HotkeyManager`.
    public static func resolve(overrides: [ShortcutOverride]) -> Resolution {
        let merged = DefaultKeymap.bindings.map { defaultShortcut, action -> ResolvedBinding in
            guard let override = overrides.last(where: { $0.action == action }) else {
                return ResolvedBinding(action: action, shortcut: defaultShortcut)
            }
            let shortcut = override.keyCode.map { keyCode in
                Shortcut(keyCode: keyCode, modifierFlags: override.modifierFlags)
            }
            return ResolvedBinding(action: action, shortcut: shortcut)
        }
        return Resolution(bindings: unbindLosers(merged), conflicts: conflicts(in: merged))
    }

    /// The settings change for "the user just recorded `shortcut` for `action`",
    /// and which action lost its binding as a result.
    ///
    /// This lives here rather than in the Preferences window because it is the
    /// one piece of the recorder with a decision in it, and `App` is untested by
    /// construction. Leaving it in the view would have put the only rule that
    /// prevents two actions claiming one key in the only layer nothing checks.
    ///
    /// The displaced action is *unbound* rather than left to collide. Refusing
    /// the new binding instead reads as a broken recorder — the user pressed
    /// keys and nothing happened — and allowing the collision would leave
    /// `RegisterEventHotKey` to reject one of them at the next launch, silently
    /// and in an order the user cannot predict. Returning the displaced action
    /// lets the caller say whose shortcut it took, which is the part that makes
    /// this honest rather than merely convenient.
    public static func assigning(
        _ shortcut: Shortcut,
        to action: Action,
        in overrides: [ShortcutOverride]
    ) -> (overrides: [ShortcutOverride], displaced: [Action]) {
        let current = resolve(overrides: overrides)
        var displaced = current.bindings.compactMap {
            $0.shortcut == shortcut && $0.action != action ? $0.action : nil
        }
        // Also the overrides `resolve` cannot see. `resolve` merges into
        // `DefaultKeymap`, so an override for an action that has no default —
        // the four `space.*` bindings a SizeUp import creates, before Spaces
        // exists — is absent from `current.bindings` and could not be displaced.
        // Left in the file it becomes a hidden second claim on this key, which
        // stays inert only until `space` gains a default and one of them is
        // unbound silently: exactly the "presses a key that will never work
        // again" outcome the import alert was written to prevent.
        let known = current.bindings.map(\.action)
        for override in overrides
        where !known.contains(override.action) && override.action != action {
            guard let keyCode = override.keyCode else { continue }
            guard Shortcut(keyCode: keyCode, modifierFlags: override.modifierFlags) == shortcut
            else { continue }
            displaced.append(override.action)
        }

        var next = overrides.filter { $0.action != action }
        next.append(
            ShortcutOverride(
                action: action,
                keyCode: shortcut.keyCode,
                modifierFlags: shortcut.modifierFlags
            )
        )
        for loser in displaced {
            // An explicit unbind entry, not merely the absence of one: absence
            // means "use the default", and the default is very likely the
            // shortcut we just took away.
            next.removeAll { $0.action == loser }
            next.append(
                ShortcutOverride(action: loser, keyCode: nil, modifierFlags: 0)
            )
        }
        return (next, displaced)
    }

    /// Groups `bindings` by shortcut, keeping only shortcuts held by more
    /// than one action.
    ///
    /// Unbound actions (`shortcut == nil`) never contribute to a group —
    /// there is no shortcut to collide on — so an unbound action can never
    /// appear here, whether it lost a conflict or was never bound at all.
    /// This is deliberately generic over any `[ResolvedBinding]`, not just
    /// `resolve`'s own (already-deduplicated) output, so it can report on
    /// what a hand-edited overrides file actually asked for before
    /// `resolve` corrects it.
    public static func conflicts(in bindings: [ResolvedBinding]) -> [Shortcut: [Action]] {
        var byShortcut: [Shortcut: [Action]] = [:]
        for binding in bindings {
            guard let shortcut = binding.shortcut else { continue }
            byShortcut[shortcut, default: []].append(binding.action)
        }
        return byShortcut.filter { $0.value.count > 1 }
    }

    /// Keeps the first claimant of each shortcut, in the order `bindings`
    /// already carries them (`DefaultKeymap` order, since that is `resolve`'s
    /// only caller), and unbinds the rest.
    private static func unbindLosers(_ bindings: [ResolvedBinding]) -> [ResolvedBinding] {
        var claimed: Set<Shortcut> = []
        return bindings.map { binding in
            guard let shortcut = binding.shortcut else { return binding }
            if claimed.contains(shortcut) {
                return ResolvedBinding(action: binding.action, shortcut: nil)
            }
            claimed.insert(shortcut)
            return binding
        }
    }
}
