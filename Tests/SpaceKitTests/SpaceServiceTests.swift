import Foundation
import Testing
@testable import SpaceKit
@testable import Geometry

/// Shaped like the real output of `SLSCopyManagedDisplaySpaces` on this
/// machine, captured in probe.swift: a built-in display with ManagedSpaceIDs
/// [1, 3] and an external display with [288].
private func realMachineFixture() -> [[String: Any]] {
    [
        [
            "Display Identifier": "built-in",
            "Current Space": ["ManagedSpaceID": 1, "type": 0],
            "Spaces": [
                ["ManagedSpaceID": 1, "type": 0],
                ["ManagedSpaceID": 3, "type": 0],
            ],
        ],
        [
            "Display Identifier": "external",
            "Current Space": ["ManagedSpaceID": 288, "type": 0],
            "Spaces": [
                ["ManagedSpaceID": 288, "type": 0],
            ],
        ],
    ]
}

@Test func parsesTheRealMachinesLayoutIntoTwoDisplays() {
    let layouts = SpaceService.parse(realMachineFixture())
    #expect(layouts.count == 2)
    #expect(layouts[0].displayIdentifier == "built-in")
    #expect(layouts[0].spaces == [SpaceIdentifier(1), SpaceIdentifier(3)])
    #expect(layouts[0].current == SpaceIdentifier(1))
    #expect(layouts[1].displayIdentifier == "external")
    #expect(layouts[1].spaces == [SpaceIdentifier(288)])
    #expect(layouts[1].current == SpaceIdentifier(288))
}

@Test func missingDisplayIdentifierDropsThatDisplayRatherThanTrapping() {
    let fixture: [[String: Any]] = [
        ["Current Space": ["ManagedSpaceID": 1], "Spaces": [["ManagedSpaceID": 1]]]
    ]
    #expect(SpaceService.parse(fixture).isEmpty)
}

@Test func missingCurrentSpaceDropsThatDisplayRatherThanTrapping() {
    // Without a current space there is nothing sensible to report even if
    // the strip itself parsed, so the whole display entry is dropped.
    let fixture: [[String: Any]] = [
        ["Display Identifier": "built-in", "Spaces": [["ManagedSpaceID": 1]]]
    ]
    #expect(SpaceService.parse(fixture).isEmpty)
}

@Test func spacesArrayOfWrongShapeYieldsAnEmptyStripNotATrap() {
    // "Spaces" present but not an array of dictionaries at all, e.g. a
    // future macOS changing the shape entirely.
    let fixture: [[String: Any]] = [
        [
            "Display Identifier": "built-in",
            "Current Space": ["ManagedSpaceID": 1],
            "Spaces": "not an array",
        ]
    ]
    let layouts = SpaceService.parse(fixture)
    #expect(layouts.count == 1)
    #expect(layouts[0].spaces.isEmpty)
}

@Test func spaceDictionaryWithoutManagedSpaceIDIsSkippedNotSubstituted() {
    // One malformed entry in the strip must not become a bogus 0 or drop
    // the rest of the strip with it.
    let fixture: [[String: Any]] = [
        [
            "Display Identifier": "built-in",
            "Current Space": ["ManagedSpaceID": 1],
            "Spaces": [["ManagedSpaceID": 1], ["type": 0], ["ManagedSpaceID": 3]],
        ]
    ]
    let layouts = SpaceService.parse(fixture)
    #expect(layouts.count == 1)
    #expect(layouts[0].spaces == [SpaceIdentifier(1), SpaceIdentifier(3)])
}

@Test func emptyTopLevelArrayParsesToNoDisplaysWithoutTrapping() {
    #expect(SpaceService.parse([]).isEmpty)
}

@Test func serviceBackedByAMissingSkyLightHandleIsUnavailable() {
    // No real SkyLight handle involved: SkyLight's `init(handle:)` accepts
    // a nil handle explicitly, simulating a future macOS that dropped the
    // framework or renamed every symbol.
    let service = SpaceService(sky: SkyLight(handle: nil))
    #expect(!service.isAvailable)
}

@Test func serviceIsUnavailableWhenOnlySwitchingSpacesSymbolIsMissing() {
    // Every other symbol resolved except SLSManagedDisplaySetCurrentSpace:
    // `activate` alone would fail safely, but `isAvailable` must also
    // report false, since a caller checking it once should not be told
    // everything works when one entry point cannot.
    let sky = SkyLight(
        connectionID: { 1 },
        copyManagedDisplaySpaces: { _ in [] as CFArray },
        moveWindowsToManagedSpace: { _, _, _ in },
        copySpacesForWindows: { _, _, _ in [] as CFArray },
        managedDisplaySetCurrentSpace: nil
    )
    #expect(!SpaceService(sky: sky).isAvailable)
}

@Test func serviceIsUnavailableWhenOnlyTheSpacesForWindowsSymbolIsMissing() {
    // `spaces(of:)` would fail safely on its own, but a caller checking
    // `isAvailable` once should not be told everything works when one
    // entry point cannot — this is the mirror of the switching-space case
    // above, for the other symbol `isAvailable` must also gate on.
    let sky = SkyLight(
        connectionID: { 1 },
        copyManagedDisplaySpaces: { _ in [] as CFArray },
        moveWindowsToManagedSpace: { _, _, _ in },
        copySpacesForWindows: nil,
        managedDisplaySetCurrentSpace: { _, _, _ in }
    )
    #expect(!SpaceService(sky: sky).isAvailable)
}

@Test func unavailableServiceDegradesEveryEntryPointToFailureRatherThanCrashing() {
    let service = SpaceService(sky: SkyLight(handle: nil))
    #expect(service.displaySpaces().isEmpty)
    #expect(service.spaces(of: 42).isEmpty)
    #expect(!service.move(windowID: 42, to: SpaceIdentifier(1)))
    #expect(!service.activate(SpaceIdentifier(1), onDisplay: "built-in"))
}
