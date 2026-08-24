import Geometry

/// A user's override for one action's shortcut, as stored in the settings
/// file.
///
/// `keyCode: nil` means deliberately unbound, which is a different thing
/// from the action simply not appearing in `Settings.shortcutOverrides`: an
/// absent entry keeps whatever `DefaultKeymap` ships, an entry with a nil
/// `keyCode` turns the shortcut off. Without this distinction there is no
/// way to disable a default shortcut at all.
public struct ShortcutSetting: Codable, Equatable, Sendable {
    public let action: String
    public let keyCode: UInt32?
    public let modifierFlags: UInt

    public init(action: String, keyCode: UInt32?, modifierFlags: UInt) {
        self.action = action
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    /// `nil` when `action` is not one of the 15 known identifiers, or when a
    /// binding (a non-nil `keyCode`) carries none of Control/Option/Command.
    /// A global hotkey with no real modifier steals that key from the whole
    /// system — plain `A`, or Shift-only — and the app cannot recover from a
    /// user binding one, so it is refused here rather than trusted.
    ///
    /// An unbind entry (`keyCode: nil`) is exempt from the modifier check:
    /// there is nothing to steal, and refusing to unbind because the stored
    /// `modifierFlags` happens to be 0 would make the unbind un-persistable.
    public var resolved: (action: Action, keyCode: UInt32?, modifierFlags: UInt)? {
        guard let action = ActionIdentifier.action(for: action) else { return nil }
        if let keyCode {
            guard keyCode <= ActionIdentifier.maximumKeyCode else { return nil }
            guard ActionIdentifier.hasRealModifier(modifierFlags) else { return nil }
        }
        return (action, keyCode, modifierFlags)
    }
}

/// The string identifiers actions are stored under, and the mapping back to
/// `Action`.
///
/// `Action` has associated values, so its synthesized `Codable` conformance
/// would produce nested objects that are coupled to case declaration order
/// and spelling — unpleasant to hand-edit, and silently wrong after a
/// refactor. A stable string table is the DTO layer's whole job, and it gives
/// an unknown identifier (a future version's action, a typo) an obvious
/// place to be ignored rather than to throw.
public enum ActionIdentifier {
    public static func action(for identifier: String) -> Action? {
        switch identifier {
        case "half.left": return .half(.left)
        case "half.right": return .half(.right)
        case "half.top": return .half(.top)
        case "half.bottom": return .half(.bottom)
        case "quarter.upperLeft": return .quarter(.upperLeft)
        case "quarter.upperRight": return .quarter(.upperRight)
        case "quarter.lowerLeft": return .quarter(.lowerLeft)
        case "quarter.lowerRight": return .quarter(.lowerRight)
        case "center": return .center
        case "fullScreen": return .fullScreen
        case "snapBack": return .snapBack
        case "display.next": return .display(.next)
        case "display.previous": return .display(.previous)
        case "display.above": return .display(.above)
        case "display.below": return .display(.below)
        case "space.next": return .space(.next)
        case "space.previous": return .space(.previous)
        case "space.above": return .space(.above)
        case "space.below": return .space(.below)
        // The capture side of the merge (ClipShot). Dotted identifiers, same
        // convention as the display/space actions, so a hand-edited settings
        // file reads the same way.
        case "capture.screenshot": return .captureScreenshot
        case "capture.record": return .startRecording
        default: return nil
        }
    }

    /// Exhaustive over `Action` so a future case fails to compile here
    /// instead of silently having no identifier.
    public static func identifier(for action: Action) -> String {
        switch action {
        case .half(.left): return "half.left"
        case .half(.right): return "half.right"
        case .half(.top): return "half.top"
        case .half(.bottom): return "half.bottom"
        case .quarter(.upperLeft): return "quarter.upperLeft"
        case .quarter(.upperRight): return "quarter.upperRight"
        case .quarter(.lowerLeft): return "quarter.lowerLeft"
        case .quarter(.lowerRight): return "quarter.lowerRight"
        case .center: return "center"
        case .fullScreen: return "fullScreen"
        case .snapBack: return "snapBack"
        case .display(.next): return "display.next"
        case .display(.previous): return "display.previous"
        case .display(.above): return "display.above"
        case .display(.below): return "display.below"
        case .space(.next): return "space.next"
        case .space(.previous): return "space.previous"
        case .space(.above): return "space.above"
        case .space(.below): return "space.below"
        case .captureScreenshot: return "capture.screenshot"
        case .startRecording: return "capture.record"
        }
    }

    /// Raw values match `NSEvent.ModifierFlags`, which is what `Hotkeys`
    /// stores and what `Shortcut.modifierFlags` expects. `Config` cannot
    /// import AppKit (house rule 6), so the three bits that matter — Control,
    /// Option, Command — are reproduced here as plain integers rather than
    /// pulled from a framework this module has no business depending on.
    ///
    /// Internal rather than private so a test can read the actual values and
    /// compare them against `NSEvent`. A test that re-states the literals
    /// instead agrees with any typo it is meant to catch.
    static let control: UInt = 1 << 18
    static let option: UInt = 1 << 19
    static let command: UInt = 1 << 20

    /// Public so the shortcut recorder can apply the same rule it will be
    /// judged by. A second, private copy in the UI meant the recorder could
    /// accept a chord this type would then discard on the next load — a
    /// shortcut that works until relaunch and then silently does not.
    public static func hasRealModifier(_ flags: UInt) -> Bool {
        flags & (control | option | command) != 0
    }

    /// Virtual key codes are 16-bit. Anything larger cannot be a real key, and
    /// converting it for `UCKeyTranslate` traps rather than failing, so it is
    /// rejected at the boundary as well as guarded where it is used.
    static let maximumKeyCode = UInt32(UInt16.max)
}
