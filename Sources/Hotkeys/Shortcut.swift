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
}

/// A global keyboard shortcut.
///
/// `modifierFlags` holds `NSEvent.ModifierFlags` raw values, which is what
/// SizeUp stores and what AppKit reports. Carbon needs a different bitmask,
/// produced by `carbonModifiers`.
public struct Shortcut: Hashable, Sendable {
    public let keyCode: UInt32
    public let modifierFlags: UInt

    public init(keyCode: UInt32, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

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
        return out + Self.keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        switch code {
        case KeyCode.leftArrow: return "←"
        case KeyCode.rightArrow: return "→"
        case KeyCode.downArrow: return "↓"
        case KeyCode.upArrow: return "↑"
        case KeyCode.m: return "M"
        case KeyCode.c: return "C"
        case KeyCode.slash: return "/"
        default: return "?"
        }
    }
}
