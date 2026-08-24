import Foundation

/// The result of reading an installed ClipShot's `config.ini`.
///
/// Mirrors `SizeUpImport`. `skipped` names the hotkeys that were present in the
/// file but could not be turned into a binding, so a partial import cannot
/// masquerade as a complete one in the confirm/report dialog.
public struct ClipShotImport: Equatable, Sendable {
    public let overrides: [ShortcutSetting]
    /// The INI keys (`"capture_hotkey"`, …) that were present but unreadable —
    /// a malformed combo, an unrecognized key, or a combo with no real modifier.
    public let skipped: [String]

    public init(overrides: [ShortcutSetting], skipped: [String]) {
        self.overrides = overrides
        self.skipped = skipped
    }
}

/// Reads an installed ClipShot's `config.ini` and produces the `ShortcutSetting`s
/// it can be turned into — the migration path for anyone who rebound ClipShot's
/// capture hotkeys before the merge.
///
/// Symmetric to `SizeUpImporter` on purpose: `Config` does the parsing (it must
/// not import `Hotkeys`/Carbon/AppKit), the keys are plain strings, and the
/// three hotkeys map onto the three capture `ActionIdentifier`s.
///
/// The INI is **left untouched** by a read — the caller imports the shortcuts
/// into the user's own settings file, and the Rust ClipShot (still installed,
/// pending uninstall) can keep using its own `config.ini` until the user deletes
/// it. Reading has no side effect.
public enum ClipShotImporter {
    /// INI key → this app's action identifier.
    private static let keyToAction: [(key: String, action: String)] = [
        ("capture_hotkey", "capture.screenshot"),
        ("record_hotkey", "capture.record"),
        ("scroll_capture_hotkey", "capture.scrollCapture"),
    ]

    /// `~/.config/clipshot/config.ini` — the same path the Rust app reads
    /// (`$XDG_CONFIG_HOME/clipshot/config.ini`, defaulting to `~/.config`).
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("clipshot", isDirectory: true)
            .appendingPathComponent("config.ini")
    }

    /// Read a `config.ini` at `url`.
    ///
    /// A missing file, an unreadable file, and any individual malformed hotkey all
    /// degrade gracefully: the file's readable hotkeys import, the unreadable ones
    /// are named in `skipped`, and nothing throws. `read` must survive being
    /// pointed at nothing, because the file can vanish between the caller's
    /// existence check and this call.
    public static func read(at url: URL) -> ClipShotImport {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return ClipShotImport(overrides: [], skipped: [])
        }
        let values = parseINI(content)

        var overrides: [ShortcutSetting] = []
        var skipped: [String] = []

        for entry in keyToAction {
            guard let value = values[entry.key] else { continue }  // absent: not a failure
            let combo = unquote(value).trimmingCharacters(in: .whitespaces)
            guard !combo.isEmpty else {
                skipped.append(entry.key)
                continue
            }
            guard let parsed = ComboParser.parse(combo) else {
                skipped.append(entry.key)
                continue
            }
            let setting = ShortcutSetting(
                action: entry.action,
                keyCode: parsed.keyCode,
                modifierFlags: parsed.modifierFlags
            )
            // The same rule that guards a hand-edited settings file guards an
            // imported one: a binding with no real modifier is refused, not
            // trusted, and reported.
            guard setting.resolved != nil else {
                skipped.append(entry.key)
                continue
            }
            overrides.append(setting)
        }

        return ClipShotImport(overrides: overrides, skipped: skipped)
    }

    // MARK: A small INI reader

    /// Parse the flat `key = value` lines the ClipShot `config.ini` uses.
    ///
    /// Deliberately minimal — the file's schema is `key = value` lines with
    /// optional `[section]` headers and `#`/`;` comments — so a purpose-built
    /// parser is honest here and a general INI library is not warranted. Lines
    /// without `=` are ignored; a later `key` overrides an earlier one, matching
    /// the Rust reader's last-wins behavior.
    static func parseINI(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in content.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip comments and section headers.
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("[") {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// ClipShot quotes its hotkey values (`"Ctrl+Cmd+A"`); strip the surrounding
    /// quotes when present.
    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
