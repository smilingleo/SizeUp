import Testing
import Foundation
import Geometry
import Hotkeys
import Config
@testable import Core

/// The real assertion for the SizeUp import: `Tests/Fixtures/sizeup-user-config.plist`
/// is where `DefaultKeymap`'s literals were transcribed from in the first
/// place, so importing it and resolving the result must reproduce
/// `DefaultKeymap.bindings` exactly for every action that plist actually
/// binds. This checks the mapping table against the real file, not against
/// whatever the implementer happened to type into `DefaultKeymap` and again
/// into `SizeUpImporter` — the two could agree with each other and both be
/// wrong about SizeUp.
///
/// Lives here rather than in `ConfigTests` because it needs `KeymapResolver`
/// (Core) and `SizeUpImporter` (Config) in the same place, and `Core` must
/// not depend on `Config` in the product itself — only this test target does.
@Suite
struct SizeUpImportRoundTripTests {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sizeup-user-config.plist")
    }

    /// The boundary translation `App` performs for real, reproduced here
    /// rather than imported, because `Core` cannot import `Config` and this
    /// is deliberately the same trivial `compactMap` the plan describes for
    /// `App`'s share of the merge.
    private func overrides(from settings: [ShortcutSetting]) -> [ShortcutOverride] {
        settings.compactMap { setting in
            guard let resolved = setting.resolved else { return nil }
            return ShortcutOverride(
                action: resolved.action,
                keyCode: resolved.keyCode,
                modifierFlags: resolved.modifierFlags
            )
        }
    }

    @Test func importingTheRealSizeUpFileReproducesDefaultKeymapForEveryBoundAction() throws {
        let imported = SizeUpImporter.read(at: fixtureURL)
        // Space Above/Space Below are skipped: macOS has had a single
        // horizontal strip of Spaces per display since Lion, so neither has
        // a real neighbour to move to.
        #expect(imported.skipped == ["Space Above", "Space Below"])

        let resolved = KeymapResolver.resolve(overrides: overrides(from: imported.overrides)).bindings

        #expect(DefaultKeymap.bindings.count == 17) // 15 window + 2 capture (the merge)

        for (defaultShortcut, action) in DefaultKeymap.bindings {
            let binding = try #require(resolved.first { $0.action == action })
            #expect(binding.shortcut == defaultShortcut)
        }
    }
}
