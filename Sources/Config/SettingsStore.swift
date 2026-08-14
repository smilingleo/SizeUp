import Foundation

/// Owns the on-disk settings file and the in-memory `Settings` that mirrors
/// it.
///
/// Marked `@MainActor` rather than `Sendable`: it holds mutable state
/// (`settings`) and is driven exclusively by UI actions (launch, and the
/// Preferences window's save-on-edit), never from a background queue. Main-
/// actor isolation is the honest description of that usage and rules out
/// accidental concurrent mutation without requiring any locking of its own.
@MainActor
public final class SettingsStore {
    private let url: URL

    public private(set) var settings: Settings

    public init(url: URL) {
        self.url = url
        self.settings = Settings()
    }

    /// `~/Library/Application Support/Sizeup2/settings.json`.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sizeup2").appendingPathComponent("settings.json")
    }

    /// Total: never throws, never crashes. A missing file, an unreadable
    /// file, malformed JSON, or JSON of the wrong shape all yield
    /// `Settings()`. A window manager that refuses to start because its
    /// config file is corrupt is strictly worse than one that starts with
    /// defaults — the user's shortcuts are muscle memory, and losing them
    /// to a stray keystroke in a text editor is unacceptable.
    ///
    /// Reading is not a mutation: this must never create the file or its
    /// containing directory.
    public func load() {
        guard let data = try? Data(contentsOf: url) else {
            settings = Settings()
            return
        }
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            // Keep the unreadable file beside the good one before defaults take
            // over. Otherwise the first subsequent save overwrites it, and a
            // single missing brace silently costs the user every preference —
            // the one remaining path in this type that destroys recoverable data.
            // Best-effort: failing to make the copy must not stop the app.
            try? data.write(to: url.appendingPathExtension("invalid"))
            settings = Settings()
            return
        }
        settings = decoded
    }

    /// Writes atomically: encode to a sibling temp file, then
    /// `replaceItemAt`. A crash mid-write must not leave a truncated file
    /// on the real path, because the next `load()` would silently reset
    /// every preference — data loss disguised as a fresh start.
    public func save(_ new: Settings) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(new)

        // Sibling temp file, not a fixed name, so concurrent saves (there
        // shouldn't be any, but this is cheap insurance) cannot collide.
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }

        settings = new
    }
}
