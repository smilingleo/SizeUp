import Foundation

/// The result of reading an installed SizeUp's preferences.
///
/// `skipped` exists so a partial import cannot masquerade as a complete one:
/// `overrides` alone cannot distinguish "SizeUp had 17 keys and all 17
/// mapped" from "SizeUp had 17 keys and 12 were unreadable", and the caller
/// (the menu item, eventually) needs to say which happened.
public struct SizeUpImport: Equatable, Sendable {
    public let overrides: [ShortcutSetting]
    /// The SizeUp key names (`"Left"`, `"Space Above"`, …) that were present
    /// in the file but could not be turned into a `ShortcutSetting` — missing
    /// or non-dictionary entries, missing `ComboCode`/`ComboFlags`, or a
    /// combination with no real modifier. Keys the plist simply does not
    /// mention are not reported here: they were never "present but unusable",
    /// they were absent, and a user who never rebound Space Above should not
    /// see it listed as a failure.
    public let skipped: [String]

    public init(overrides: [ShortcutSetting], skipped: [String]) {
        self.overrides = overrides
        self.skipped = skipped
    }
}

/// Reads an installed SizeUp's preferences plist and produces the
/// `ShortcutSetting`s it can be turned into.
///
/// `Config` still must not import `Hotkeys`/Carbon/AppKit (house rule), which
/// this satisfies the same way `ShortcutSetting` does: everything here is
/// `PropertyListSerialization` and plain integers.
public enum SizeUpImporter {
    /// SizeUp key name to this app's action identifier, taken from the real
    /// preferences file in `Tests/Fixtures/sizeup-user-config.plist`, not
    /// from memory or from SizeUp's documentation — the plan for this task
    /// exists specifically because the flags key (`ComboFlags`, not
    /// `ComboModifiers`) does not match what a plausible guess would produce.
    private static let keyToAction: [String: String] = [
        "Left": "half.left",
        "Right": "half.right",
        "Up": "half.top",
        "Down": "half.bottom",
        "Upper Left": "quarter.upperLeft",
        "Upper Right": "quarter.upperRight",
        "Lower Left": "quarter.lowerLeft",
        "Lower Right": "quarter.lowerRight",
        "Full Screen": "fullScreen",
        "Center": "center",
        "SnapBack": "snapBack",
        "Next Monitor": "display.next",
        "Prev Monitor": "display.previous",
        "Space Next": "space.next",
        "Space Prev": "space.previous",
    ]

    /// SizeUp keys deliberately never turned into a binding: macOS has had a
    /// single horizontal strip of Spaces per display since Lion, so there is
    /// no vertical neighbour for either to reach. Mapping them to next/previous
    /// would be behaviour invented rather than reproduced — see
    /// `SpaceSequence`'s doc comment — so they are reported as skipped instead
    /// of silently dropped, and the import alert can name them.
    private static let alwaysSkipped: Set<String> = ["Space Above", "Space Below"]

    /// SizeUp stores its preferences the ordinary `NSUserDefaults` way: a
    /// plist named after its bundle identifier under `~/Library/Preferences`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("com.irradiatedsoftware.SizeUp.plist")
    }

    /// Total: a missing file, an unreadable file, a plist whose root is not a
    /// dictionary, or any individual entry that is malformed all degrade to
    /// "not imported" for that entry rather than throwing. The caller is
    /// expected to check `SizeUpImporter.defaultURL` exists before offering
    /// the menu item at all, but `read` itself must survive being pointed at
    /// nothing, because the file can vanish between that check and this call.
    public static func read(at url: URL) -> SizeUpImport {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let root = plist as? [String: Any]
        else {
            return SizeUpImport(overrides: [], skipped: [])
        }

        var overrides: [ShortcutSetting] = []
        var skipped: [String] = []

        // `alwaysSkipped` entries never had a `keyToAction` mapping to begin
        // with (there is no `Action` for them), so they are reported here,
        // before the loop below, rather than falling out of it naturally.
        // Only reported when present: absent is not the same as unusable.
        for sizeUpKey in alwaysSkipped.sorted() where root[sizeUpKey] != nil {
            skipped.append(sizeUpKey)
        }

        // Sorted, because iterating the dictionary directly made the order of
        // `overrides` — and so the order of the array written to settings.json —
        // differ between runs. A file that reshuffles itself for no reason is
        // hostile to anyone hand-editing it or diffing it.
        for sizeUpKey in keyToAction.keys.sorted() {
            guard let action = keyToAction[sizeUpKey] else { continue }
            // A key the user's SizeUp simply never had (never rebound, or an
            // older version without Spaces support) is not a failure — it is
            // absent, not "present but unusable" — so it is skipped over
            // silently rather than added to `skipped`.
            guard let entry = root[sizeUpKey] else { continue }

            guard
                let entryDict = entry as? [String: Any],
                let comboCode = entryDict["ComboCode"] as? Int,
                let comboFlags = entryDict["ComboFlags"] as? Int
            else {
                skipped.append(sizeUpKey)
                continue
            }

            let setting = ShortcutSetting(
                action: action,
                keyCode: UInt32(truncatingIfNeeded: comboCode),
                modifierFlags: UInt(bitPattern: comboFlags)
            )
            // `resolved` already refuses a binding with no real modifier —
            // the same rule that protects a hand-edited settings file also
            // protects an imported one, so it is not duplicated here.
            guard setting.resolved != nil else {
                skipped.append(sizeUpKey)
                continue
            }
            overrides.append(setting)
        }

        return SizeUpImport(overrides: overrides, skipped: skipped)
    }
}
