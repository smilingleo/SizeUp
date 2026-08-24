import Foundation

/// Parses a `global_hotkey`-style combo string — the format ClipShot's
/// `config.ini` uses, e.g. `"Ctrl+Cmd+A"` or `"Cmd+Shift+Left"` — into a
/// virtual key code plus a modifier bitmask.
///
/// `Config` cannot import `Carbon` (house rule) or `AppKit`, so this does not
/// ask the OS to translate a character to a key code. Instead it carries a
/// small **US-layout** virtual-key table (the standard ANSI key codes) and
/// resolves the key *by name*: `A` → vkey 0, `Left` → vkey 123, and so on.
///
/// That is a deliberate and documented assumption. The US layout is what
/// ClipShot's own defaults (`Ctrl+Cmd+A/Z/S`) and the overwhelming majority of
/// user rebindings use. A key that has no name in the table (a layout
/// symbol, a key we do not enumerate) resolves to `nil` and the caller reports
/// it as skipped — the same graceful degradation the SizeUp importer uses for
/// an unreadable entry — rather than guessing a code that would bind the wrong
/// key on, say, an AZERTY machine.
///
/// The modifier bit values match `NSEvent.ModifierFlags` (which is what
/// `Hotkeys` and `Shortcut` store), reproduced here as plain integers for the
/// same reason `ActionIdentifier` does: `Config` has no business depending on
/// AppKit.
public enum ComboParser {
    /// Parsed result, or `nil` when the string cannot be a valid binding.
    public struct Result: Equatable, Sendable {
        public let keyCode: UInt32
        public let modifierFlags: UInt
    }

    // Modifier bits, `NSEvent.ModifierFlags` values without AppKit.
    static let shift: UInt = 1 << 16
    static let control: UInt = 1 << 18
    static let option: UInt = 1 << 19
    static let command: UInt = 1 << 20

    /// US-layout ANSI virtual key codes, keyed by the name `global_hotkey`
    /// accepts (case-insensitive). Letters, digits, the arrows, and the handful
    /// of other keys a window/capture hotkey plausibly uses.
    private static let keyCodes: [String: UInt32] = {
        var table: [String: UInt32] = [
            // Home row
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            // Top row: `1 2 3 4 6 5 = 9 7 - 8 0` in physical left-to-right order.
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "equal": 24,
            "7": 26, "8": 28, "9": 25, "0": 29, "minus": 27,
            // Upper-right row
            "o": 31, "u": 32, "i": 34, "p": 35,
            "l": 37, "j": 38, "k": 40, "m": 46,
            // Punctuation
            "comma": 43, "period": 47, "slash": 44,
            "bracketleft": 33, "bracketright": 30, "backslash": 42, "semicolon": 41, "quote": 39, "grave": 50,
        ]
        // Arrows and common navigation keys.
        table.merge([
            "left": 123, "right": 124, "down": 125, "up": 126,
            "escape": 53, "space": 49, "tab": 48, "backspace": 51, "delete": 117,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]) { existing, _ in existing }
        return table
    }()

    /// Accepts the modifier spellings `global_hotkey` and users actually use.
    private static let modifiers: [String: UInt] = [
        "ctrl": control, "control": control,
        "cmd": command, "command": command, "super": command,
        "alt": option, "option": option,
        "shift": shift,
    ]

    /// Parse `combo` (e.g. `"Ctrl+Cmd+A"`) into a virtual key code and
    /// modifier bits.
    ///
    /// - Returns: The `Result`, or `nil` if there is not exactly one key, the
    ///   key has no known US-layout code, or a modifier token is unrecognized.
    ///   A modifier-less combo parses here (the *presence* of a real modifier
    ///   is judged by the caller, the same rule that guards a hand-edited
    ///   settings file and a recorded binding).
    public static func parse(_ combo: String) -> Result? {
        let tokens = combo
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var keyCode: UInt32?
        var flags: UInt = 0
        var keysSeen = 0

        for token in tokens {
            let name = token.lowercased()
            if let modifier = modifiers[name] {
                flags |= modifier
            } else if let code = keyCodes[name] {
                keyCode = code
                keysSeen += 1
            } else {
                // An unrecognized token (a typo, or a key we do not enumerate)
                // makes the whole combo unparseable rather than silently wrong.
                return nil
            }
        }

        // Exactly one key: a combo with two keys ("A+B") is not a hotkey.
        guard keysSeen == 1, let keyCode else { return nil }
        return Result(keyCode: keyCode, modifierFlags: flags)
    }
}
