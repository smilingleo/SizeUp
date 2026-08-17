import Testing
import Foundation
@testable import Config

/// Each test gets its own temporary directory so tests cannot interfere
/// with each other or leave state behind on disk.
private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// The three tests below deliberately establish non-default settings FIRST.
//
// `init` already assigns `Settings()`, so asserting "load yields defaults" on a
// fresh store passes even if `load()` does nothing at all — verified by mutation:
// replacing the whole body of `load()` with a comment left all three green. They
// only constrain anything if there is non-default state for a failed load to have
// to discard, which is a real path, because the Preferences window reloads over
// live state every time it is shown.

@Test @MainActor func loadingAMissingFileYieldsDefaults() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    try store.save(Settings(gaps: GapSettings(inner: 12, outer: 6)))
    #expect(store.settings != Settings())
    try FileManager.default.removeItem(at: url)

    store.load()

    #expect(store.settings == Settings())
}

@Test @MainActor func loadingCorruptJSONYieldsDefaultsWithoutThrowing() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    try store.save(Settings(skippedBundleIdentifiers: ["com.example.one"]))
    try "{ not json".write(to: url, atomically: true, encoding: .utf8)

    store.load()

    #expect(store.settings == Settings())
}

@Test @MainActor func loadingJSONOfTheWrongShapeYieldsDefaults() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    try store.save(Settings(gaps: GapSettings(inner: 12, outer: 6)))
    try #"{"gaps": "huge"}"#.write(to: url, atomically: true, encoding: .utf8)

    store.load()

    #expect(store.settings == Settings())
}

@Test @MainActor func savedSettingsSurviveAReload() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let nonDefault = Settings(
        gaps: GapSettings(inner: 8, outer: 12),
        cycle: [SpanSetting(occupied: 1, columns: 2), SpanSetting(occupied: 1, columns: 3)],
        skippedBundleIdentifiers: ["com.example.app"]
    )

    let writer = SettingsStore(url: url)
    try writer.save(nonDefault)

    let reader = SettingsStore(url: url)
    reader.load()

    #expect(reader.settings == nonDefault)
}

@Test @MainActor func loadingCreatesNoFile() throws {
    // The directory MUST exist for this test to mean anything. Without it, a
    // `load()` that wrote defaults back would fail silently on the missing
    // directory and the test would pass for the wrong reason — verified by
    // mutation: adding a write to `load()` did not fail this test until the
    // directory was created first.
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    store.load()

    // Reading is not a mutation: a load must never conjure a file into
    // existence, even a default one.
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func savingCreatesTheContainingDirectory() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Two levels below a fresh temp dir: first launch has no Sizeup2 folder.
    let url = dir.appendingPathComponent("Sizeup2").appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    try store.save(Settings())

    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func aSecondSaveDoesNotLeaveATempFileBehind() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    try store.save(Settings())
    try store.save(Settings(gaps: GapSettings(inner: 4, outer: 4)))

    // Catches temp-file litter, which is otherwise invisible because the
    // happy path still works. It does NOT prove the write was atomic: a
    // successful `replaceItemAt` consumes the temp file, so this passes even
    // with the cleanup removed, and it passes for a plain in-place write too.
    // Atomicity proper is covered by `aFailedSaveLeavesThePreviousFileIntact`.
    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(contents.count == 1)
}

@Test @MainActor func theSavedFileIsHumanReadable() throws {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    try store.save(Settings())

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("inner"))
    #expect(text.contains("\n"))
}

@Test @MainActor func defaultURLEndsInSettingsJSONUnderSizeup2() {
    // Cannot assert the real path without touching the user's home
    // directory, so this only checks shape, and never writes to it.
    let url = SettingsStore.defaultURL
    #expect(url.lastPathComponent == "settings.json")
    #expect(url.pathComponents.contains("Sizeup2"))
}

@Test @MainActor func aFailedSaveLeavesThePreviousFileIntact() throws {
    // The point of writing through a temp file: a save that fails partway must
    // not damage what was already on disk. An in-place write would truncate the
    // file first and leave the user with defaults — data loss disguised as a
    // fresh start.
    //
    // The failure is forced by making the directory read-only, so the temp file
    // cannot be created. `chmod` on the directory, not the file: renaming into a
    // directory needs directory write permission, while the existing file's own
    // mode is irrelevant.
    let dir = makeTempDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let url = dir.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    let good = Settings(skippedBundleIdentifiers: ["com.example.keep"])
    try store.save(good)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    #expect(throws: (any Error).self) {
        try store.save(Settings(skippedBundleIdentifiers: ["com.example.lost"]))
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    let reader = SettingsStore(url: url)
    reader.load()
    #expect(reader.settings == good)
}

@Test @MainActor func aCorruptFileIsKeptAsideRatherThanOverwritten() throws {
    // A missing brace should not cost the user every preference. Without this the
    // next save silently replaces the only copy of what they had written.
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    let broken = #"{"gaps": {"inner": 12, "outer": 6}"#
    try broken.write(to: url, atomically: true, encoding: .utf8)

    let store = SettingsStore(url: url)
    store.load()

    #expect(store.settings == Settings())
    let kept = try String(contentsOf: url.appendingPathExtension("invalid"), encoding: .utf8)
    #expect(kept == broken)
}

@Test @MainActor func updatingOneFieldPreservesEveryOtherField() throws {
    // The regression this API exists to make impossible. The General tab of the
    // Preferences window predates shortcut overrides and rebuilt a whole
    // `Settings` from the three fields it knew about, so adjusting a gap silently
    // erased every rebound shortcut -- the headline feature of the milestone that
    // added them. Reconstruction loses whatever the editor has not heard of;
    // mutation cannot.
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))

    try store.save(
        Settings(
            gaps: GapSettings(inner: 8, outer: 4),
            cycle: [SpanSetting(occupied: 1, columns: 3)],
            skippedBundleIdentifiers: ["com.example.terminal"],
            shortcutOverrides: [
                ShortcutSetting(action: "center", keyCode: 105, modifierFlags: 1_835_008)
            ]
        )
    )

    try store.update { $0.gaps = GapSettings(inner: 20, outer: 10) }

    #expect(store.settings.gaps == GapSettings(inner: 20, outer: 10))
    #expect(store.settings.shortcutOverrides.count == 1)
    #expect(store.settings.shortcutOverrides.first?.action == "center")
    #expect(store.settings.cycle == [SpanSetting(occupied: 1, columns: 3)])
    #expect(store.settings.skippedBundleIdentifiers == ["com.example.terminal"])

    // And it survives a round trip, not just the in-memory copy.
    let reread = SettingsStore(url: dir.appendingPathComponent("settings.json"))
    reread.load()
    #expect(reread.settings == store.settings)
}

@Test @MainActor func aFailedUpdateDoesNotChangeTheInMemorySettings() throws {
    // `update` mutates a copy and saves it, so a save that throws must leave the
    // store reporting what is actually on disk. Reporting the attempted value
    // would make the UI show settings the router is not using.
    let dir = makeTempDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
    try store.save(Settings(gaps: GapSettings(inner: 8, outer: 4)))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

    #expect(throws: (any Error).self) {
        try store.update { $0.gaps = GapSettings(inner: 99, outer: 99) }
    }
    #expect(store.settings.gaps == GapSettings(inner: 8, outer: 4))
}
