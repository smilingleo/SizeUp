import Carbon.HIToolbox
import Foundation

/// Human-readable names for virtual key codes.
///
/// `UCKeyTranslate` returns control characters (not glyphs) for Return, Tab,
/// Escape, the arrows, and the F-keys — asking the current keyboard layout to
/// name them is asking the wrong question, since those keys do not produce
/// text. They come from `table` instead. Everything else is translated
/// against `TISCopyCurrentKeyboardInputSource`'s layout data, so a Dvorak or
/// AZERTY user sees the key they actually press rather than the QWERTY
/// position. `"Key \(keyCode)"` is the last resort — never `"?"`, which
/// cannot be told apart from "the key really is a question mark".
public enum KeyName {
    public static func of(_ keyCode: UInt32) -> String {
        if let named = table[keyCode] { return named }
        if let translated = translate(keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static let table: [UInt32: String] = [
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Escape",
        UInt32(kVK_ForwardDelete): "Forward Delete",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_F1): "F1",
        UInt32(kVK_F2): "F2",
        UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5",
        UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7",
        UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10",
        UInt32(kVK_F11): "F11",
        UInt32(kVK_F12): "F12",
        UInt32(kVK_ANSI_Keypad0): "Keypad 0",
        UInt32(kVK_ANSI_Keypad1): "Keypad 1",
        UInt32(kVK_ANSI_Keypad2): "Keypad 2",
        UInt32(kVK_ANSI_Keypad3): "Keypad 3",
        UInt32(kVK_ANSI_Keypad4): "Keypad 4",
        UInt32(kVK_ANSI_Keypad5): "Keypad 5",
        UInt32(kVK_ANSI_Keypad6): "Keypad 6",
        UInt32(kVK_ANSI_Keypad7): "Keypad 7",
        UInt32(kVK_ANSI_Keypad8): "Keypad 8",
        UInt32(kVK_ANSI_Keypad9): "Keypad 9",
        UInt32(kVK_ANSI_KeypadDecimal): "Keypad .",
        UInt32(kVK_ANSI_KeypadMultiply): "Keypad *",
        UInt32(kVK_ANSI_KeypadPlus): "Keypad +",
        UInt32(kVK_ANSI_KeypadClear): "Keypad Clear",
        UInt32(kVK_ANSI_KeypadDivide): "Keypad /",
        UInt32(kVK_ANSI_KeypadEnter): "Keypad Enter",
        UInt32(kVK_ANSI_KeypadMinus): "Keypad -",
        UInt32(kVK_ANSI_KeypadEquals): "Keypad =",
    ]

    /// Serializes access to the Carbon text-input-source APIs.
    ///
    /// `TISCopyCurrentKeyboardInputSource`/`UCKeyTranslate` are not
    /// documented as safe to call concurrently, and Swift Testing runs
    /// `@Test` functions on many threads at once by default. Calling them
    /// from several threads simultaneously was observed to abort the whole
    /// test process (signal 6) intermittently under that concurrency; a lock
    /// around the pair removes the race without opting this type out of
    /// being used from anywhere Carbon happens to be busy elsewhere.
    private static let lock = NSLock()

    /// Asks the current keyboard layout what glyph a key code produces.
    ///
    /// `kUCKeyActionDisplay` and the no-dead-keys bit ask for the plain
    /// character a key shows, not the one it would compose after a dead key
    /// (e.g. `´` before `e`) — a rebind UI needs the label on the key, not
    /// the eventual composed text.
    private static func translate(_ keyCode: UInt32) -> String? {
        // A virtual key code is 16-bit, and `UInt16(_:)` TRAPS rather than
        // failing for anything larger. That is reachable from a hand-edited
        // settings file — `"keyCode": 70000` — and from a plist ComboCode, and
        // it killed the app on every launch, since the status menu names every
        // shortcut while it is built. Verified by measurement: KeyName.of(70000)
        // aborted with "Not enough bits to represent the passed value".
        guard keyCode <= UInt16.max else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard
            let layoutDataPointer = TISGetInputSourceProperty(
                inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(layoutBytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(1 << kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
