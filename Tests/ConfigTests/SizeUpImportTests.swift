import Testing
import Foundation
@testable import Config

/// `Tests/Fixtures/sizeup-user-config.plist` is the real preferences file the
/// shipped defaults were transcribed from (see `DefaultKeymap`'s doc comment),
/// not a file invented for this test — so a mismatch here is a mismatch with
/// reality, not with a fixture the implementer also wrote.
private var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sizeup-user-config.plist")
}

@Test func importingTheFixtureYieldsThirteenKeysAndSkipsAllFourSpacesKeys() {
    let result = SizeUpImporter.read(at: fixtureURL)

    // All four Space keys are skipped, not imported: this app has no Spaces
    // feature to bind them to. Reported (not dropped) so the import alert can
    // tell a user who had them bound that they did not come across.
    #expect(result.overrides.count == 13)
    #expect(result.skipped == ["Space Above", "Space Below", "Space Next", "Space Prev"])
}

@Test func importedActionsCoverEveryHalfQuarterAndDisplayIdentifier() {
    let result = SizeUpImporter.read(at: fixtureURL)
    let actions = Set(result.overrides.map(\.action))

    let expected: Set<String> = [
        "half.left", "half.right", "half.top", "half.bottom",
        "quarter.upperLeft", "quarter.upperRight", "quarter.lowerLeft", "quarter.lowerRight",
        "fullScreen", "center", "snapBack",
        "display.next", "display.previous",
    ]
    #expect(actions == expected)
}

@Test func importedCenterMatchesTheRealFilesComboCodeAndFlags() {
    // `Center`'s literal values in the fixture, read with `plutil`, so this
    // test fails if the key name (`ComboFlags`, not `ComboModifiers`) or the
    // field mapping is wrong, not just if the count is wrong.
    let result = SizeUpImporter.read(at: fixtureURL)
    let center = result.overrides.first { $0.action == "center" }

    #expect(center?.keyCode == 8)
    #expect(center?.modifierFlags == 1_835_008)
}

@Test func aMissingFileYieldsAnEmptyResultWithoutThrowing() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("no-such-file.plist")

    let result = SizeUpImporter.read(at: missing)

    #expect(result.overrides.isEmpty)
    #expect(result.skipped.isEmpty)
}

@Test func entriesThatAreStringsInsteadOfDictionariesAreSkippedNotTrapped() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("malformed.plist")

    // "Left" is a string, not a dict with ComboCode/ComboFlags — the shape
    // SizeUp itself would never produce, but a hand-edited or truncated file
    // could.
    let plist: [String: Any] = [
        "Left": "not a dictionary",
        "Center": ["ComboCode": 8, "ComboFlags": 1_835_008],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url)

    let result = SizeUpImporter.read(at: url)

    #expect(result.skipped == ["Left"])
    #expect(result.overrides.map(\.action) == ["center"])
}

@Test func anEntryMissingComboFlagsIsSkipped() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("no-flags.plist")

    let plist: [String: Any] = ["Center": ["ComboCode": 8]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url)

    let result = SizeUpImporter.read(at: url)

    #expect(result.skipped == ["Center"])
    #expect(result.overrides.isEmpty)
}

@Test func anEntryWithNoRealModifierIsSkipped() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("shift-only.plist")

    // Shift alone (1 << 17 == 131072) steals a capital letter with no way to
    // recover from inside the app — the same rule `ShortcutSetting.resolved`
    // already enforces for hand-edited settings, exercised here through the
    // import path instead.
    let plist: [String: Any] = ["Center": ["ComboCode": 8, "ComboFlags": 131_072]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url)

    let result = SizeUpImporter.read(at: url)

    #expect(result.skipped == ["Center"])
    #expect(result.overrides.isEmpty)
}

@Test func aKeyAbsentFromTheFileIsNeitherImportedNorReportedAsSkipped() throws {
    // Absent is not the same as unusable: a user who never touched Center
    // should not see it listed as a failed import.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("just-center.plist")

    let plist: [String: Any] = ["Center": ["ComboCode": 8, "ComboFlags": 1_835_008]]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: url)

    let result = SizeUpImporter.read(at: url)

    #expect(result.overrides.map(\.action) == ["center"])
    #expect(result.skipped.isEmpty)
}

@Test func aPlistWhoseRootIsNotADictionaryYieldsAnEmptyResult() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("array-root.plist")

    let data = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dict"], format: .xml, options: 0)
    try data.write(to: url)

    let result = SizeUpImporter.read(at: url)

    #expect(result.overrides.isEmpty)
    #expect(result.skipped.isEmpty)
}

@Test func defaultURLPointsUnderLibraryPreferences() {
    // Cannot assert the exact bundle identifier is right without an installed
    // SizeUp to compare against, so this only checks shape.
    let url = SizeUpImporter.defaultURL
    #expect(url.pathComponents.contains("Preferences"))
    #expect(url.lastPathComponent.hasSuffix(".plist"))
}

/// The importer iterated a dictionary, so the order of `overrides` — and hence of
/// the array written into settings.json — varied between runs. Nothing broke, but
/// a file that reshuffles itself for no reason is hostile to read and to diff.
///
/// This has to pin the concrete expected order. Swift seeds its hashing per
/// process, so dictionary iteration is stable *within* a run and varies only
/// between runs: comparing two reads in one process would pass either way. Before
/// the fix this assertion failed intermittently from one `swift test` to the
/// next, which is exactly the symptom.
@Test func importedOverridesAreOrderedByTheirSizeUpKeyRatherThanByHashOrder() {
    let actions = SizeUpImporter.read(at: fixtureURL).overrides.map(\.action)
    #expect(actions == [
        "center",             // Center
        "half.bottom",        // Down
        "fullScreen",         // Full Screen
        "half.left",          // Left
        "quarter.lowerLeft",  // Lower Left
        "quarter.lowerRight", // Lower Right
        "display.next",       // Next Monitor
        "display.previous",   // Prev Monitor
        "half.right",         // Right
        "snapBack",           // SnapBack
        "half.top",           // Up
        "quarter.upperLeft",  // Upper Left
        "quarter.upperRight", // Upper Right
    ])
}
