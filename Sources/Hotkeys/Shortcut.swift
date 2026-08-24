import AppKit
import Carbon.HIToolbox

/// Virtual key codes. These are the values SizeUp stores as `ComboCode`.
public enum KeyCode {
    public static let leftArrow: UInt32 = 123
    public static let rightArrow: UInt32 = 124
    public static let downArrow: UInt32 = 125
    public static let upArrow: UInt32 = 126
    /// SizeUp's Full Screen default is M, for "maximize" — not F.
    public static let m: UInt32 = 46
    public static let c: UInt32 = 8
    /// SizeUp's Snap Back default.
    public static let slash: UInt32 = 44
    // The capture side of the merge. These are the standalone ClipShot defaults
    // (probe-measured, not recalled): A=0, Z=6, S=1 under ⌃⌘. `KeyCode` holds
    // them so `DefaultKeymap` can name them rather than spell the raw vkeys.
    public static let a: UInt32 = 0
    public static let z: UInt32 = 6
    public static let s: UInt32 = 1
}

/// A global keyboard shortcut.
///
/// `modifierFlags` holds `NSEvent.ModifierFlags` raw values, which is what
/// SizeUp stores and what AppKit reports. Carbon needs a different bitmask,
/// produced by `carbonModifiers`.
public struct Shortcut: Hashable, Sendable {
    public let keyCode: UInt32
    public let modifierFlags: UInt

    /// Canonicalises `modifierFlags` to the four modifiers a hotkey can carry.
    ///
    /// `NSEvent.modifierFlags` includes device-dependent bits that say WHICH
    /// physical Control or Shift key was used, so a recorded ⌃⌥⌘/ arrives as
    /// 1835049 where the same combination written down is 1835008. Since this
    /// type is `Hashable` and compared by raw value, the two were unequal, and
    /// every comparison that matters silently stopped working: conflict
    /// detection found nothing, so recording a shortcut another action already
    /// held left BOTH holding it — measured in the live UI, with Center and Snap
    /// Back displaying the same keys and no warning shown. `HotkeyManager` would
    /// then register whichever came first and have the other refused. Lookups by
    /// shortcut, such as `failure(for:)`, failed the same way.
    ///
    /// Normalising here rather than at the recorder means no future caller can
    /// reintroduce it, and the value that gets persisted is canonical too.
    public init(keyCode: UInt32, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags & Self.significantModifiers
    }

    private static let significantModifiers: UInt = NSEvent.ModifierFlags(
        [.control, .option, .shift, .command]
    ).rawValue

    /// The Carbon modifier bitmask for `RegisterEventHotKey`.
    ///
    /// Only the four real modifiers are carried across. Caps Lock, Function,
    /// and the numeric-pad bit are not part of a registered hotkey.
    public var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Human-readable form, in the modifier order macOS menus use.
    public var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + keyName
    }

    /// The label for `keyCode` alone, with no modifiers. Delegates to
    /// `KeyName` so the actual naming logic lives in one place.
    public var keyName: String {
        KeyName.of(keyCode)
    }
}
