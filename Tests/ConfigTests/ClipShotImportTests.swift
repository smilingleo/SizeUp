import Foundation
import Testing
@testable import Config

/// Reads the real `Tests/Fixtures/clipshot-config.ini` — the format the Rust
/// `config.rs` writes — and checks the three hotkeys come out as the capture
/// `ActionIdentifier`s. Lives in `ConfigTests` because `ClipShotImporter` is a
/// `Config` type (unlike the SizeUp round-trip test, which needs `Core` too).
@Suite
struct ClipShotImportTests {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/clipshot-config.ini")
    }

    @Test func theFixtureImportsThreeCaptureOverrides() {
        let result = ClipShotImporter.read(at: fixtureURL)
        // The fixture has all three hotkeys, all bound, none skipped.
        #expect(result.overrides.count == 3)
        #expect(result.skipped.isEmpty)

        let actions = Set(result.overrides.map(\.action))
        #expect(actions == Set(["capture.screenshot", "capture.record", "capture.scrollCapture"]))

        // The defaults map onto the same vkeys the Swift `DefaultKeymap` uses
        // for the capture actions (A/Z/S under Ctrl+Cmd): importing the
        // stock file is a no-op, which is the point of the migration.
        let byAction = Dictionary(uniqueKeysWithValues: result.overrides.map { ($0.action, $0) })
        #expect(byAction["capture.screenshot"]?.keyCode == 0)   // A
        #expect(byAction["capture.record"]?.keyCode == 6)       // Z
        #expect(byAction["capture.scrollCapture"]?.keyCode == 1) // S
    }

    @Test func aReboundHotkeyImportsItsRebinding() {
        // A file the user changed is the whole reason the importer exists.
        let url = tempINI(
            "capture_hotkey=\"Ctrl+Alt+G\"\n"
            + "record_hotkey=\"Ctrl+Cmd+Z\"\n"
            + "scroll_capture_hotkey=\"Ctrl+Cmd+S\"\n"
        )
        let result = ClipShotImporter.read(at: url)
        #expect(result.skipped.isEmpty)
        let capture = result.overrides.first { $0.action == "capture.screenshot" }
        #expect(capture?.keyCode == 5)                    // G
        #expect(capture?.modifierFlags == (1 << 18) | (1 << 19)) // Ctrl+Alt
    }

    @Test func anUnreadableHotkeyIsSkippedNotThrown() {
        let url = tempINI(
            "capture_hotkey=\"\"\n"                          // empty
            + "record_hotkey=\"Ctrl+Cmd+Z\"\n"
            + "scroll_capture_hotkey=\"Cmd+Ü\"\n"           // unparseable key
        )
        let result = ClipShotImporter.read(at: url)
        #expect(result.overrides.count == 1)               // only record
        #expect(Set(result.skipped) == Set(["capture_hotkey", "scroll_capture_hotkey"]))
    }

    @Test func aModifierlessHotkeyIsRefused() {
        // "A" parses, but a global hotkey with no real modifier is refused by
        // `ShortcutSetting.resolved` and reported, not trusted.
        let url = tempINI("capture_hotkey=\"A\"\n")
        let result = ClipShotImporter.read(at: url)
        #expect(result.overrides.isEmpty)
        #expect(result.skipped == ["capture_hotkey"])
    }

    @Test func aMissingFileImportsNothing() {
        let missing = fixtureURL.appendingPathComponent("does-not-exist.ini")
        let result = ClipShotImporter.read(at: missing)
        #expect(result.overrides.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test func anUnquotedHotkeyValueIsAccepted() {
        let url = tempINI("capture_hotkey=Ctrl+Cmd+A\n")
        let result = ClipShotImporter.read(at: url)
        #expect(result.overrides.count == 1)
        #expect(result.overrides.first?.keyCode == 0)
    }

    /// Write a `config.ini`-shaped string to a temp file and return its URL.
    private func tempINI(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshot-import-\(UUID().uuidString).ini")
        try? Data(body.utf8).write(to: url)
        return url
    }
}
