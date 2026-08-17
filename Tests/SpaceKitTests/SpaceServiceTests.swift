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
        ["Current Space": ["ManagedSpaceID": 1, "type": 0], "Spaces": [["ManagedSpaceID": 1, "type": 0]]]
    ]
    #expect(SpaceService.parse(fixture).isEmpty)
}

@Test func missingCurrentSpaceDropsThatDisplayRatherThanTrapping() {
    // Without a current space there is nothing sensible to report even if
    // the strip itself parsed, so the whole display entry is dropped.
    let fixture: [[String: Any]] = [
        ["Display Identifier": "built-in", "Spaces": [["ManagedSpaceID": 1, "type": 0]]]
    ]
    #expect(SpaceService.parse(fixture).isEmpty)
}

@Test func spacesArrayOfWrongShapeYieldsAnEmptyStripNotATrap() {
    // "Spaces" present but not an array of dictionaries at all, e.g. a
    // future macOS changing the shape entirely.
    let fixture: [[String: Any]] = [
        [
            "Display Identifier": "built-in",
            "Current Space": ["ManagedSpaceID": 1, "type": 0],
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
            "Current Space": ["ManagedSpaceID": 1, "type": 0],
            "Spaces": [["ManagedSpaceID": 1, "type": 0], ["type": 0], ["ManagedSpaceID": 3, "type": 0]],
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

/// The exact strip this machine reported while TextEdit was full-screen, captured
/// rather than imagined: `[1 (type 0), 398 (type 4), 3 (type 0)]`.
///
/// The full-screen Space sits BETWEEN the user's two Spaces, so before this was
/// filtered, "next Space" from Space 1 targeted 398 — moving the window into
/// TextEdit's full-screen Space and, with following on by default, taking the user
/// there too. The window is then invisible behind another application's
/// full-screen window. This happens on any Mac with a full-screen app open, which
/// is most of them.
@Test func aFullScreenApplicationsSpaceIsNotATargetEvenThoughItSitsInTheStrip() throws {
    let layouts = SpaceService.parse([
        [
            "Display Identifier": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            "Current Space": ["ManagedSpaceID": 1, "type": 0],
            "Spaces": [
                ["ManagedSpaceID": 1, "type": 0],
                ["ManagedSpaceID": 398, "type": 4],
                ["ManagedSpaceID": 3, "type": 0],
            ],
        ]
    ])

    let layout = try #require(layouts.first)
    #expect(layout.spaces == [SpaceIdentifier(1), SpaceIdentifier(3)])
    #expect(!layout.spaces.contains(SpaceIdentifier(398)))
}

/// A Space with no `type` at all, or an unrecognised one, is excluded.
///
/// Excluding anything that is not plainly `type: 0` rather than excluding a known
/// list of bad values: a `type` never seen before is far likelier to be another
/// system-managed Space than a new kind of user Space, and the costs are not
/// symmetric — wrongly excluding gives a shortcut that does nothing, wrongly
/// including hides the user's window inside another application.
@Test func aSpaceWhoseTypeIsUnrecognisedOrMissingIsNotATarget() throws {
    let layouts = SpaceService.parse([
        [
            "Display Identifier": "display",
            "Current Space": ["ManagedSpaceID": 1, "type": 0],
            "Spaces": [
                ["ManagedSpaceID": 1, "type": 0],
                ["ManagedSpaceID": 2],
                ["ManagedSpaceID": 3, "type": 99],
                ["ManagedSpaceID": 4, "type": "0"],
            ],
        ]
    ])

    let layout = try #require(layouts.first)
    #expect(layout.spaces == [SpaceIdentifier(1)])
}

/// `UInt64(_:)` traps on a negative value rather than failing.
///
/// This project has already shipped two launch-killing traps of exactly this
/// shape, both reachable from data it did not control, and both in files whose
/// comments claimed the input was validated. Measured again here before fixing:
/// `UInt64(-5)` aborts the process. A private API on a future macOS is precisely
/// data this code does not control.
@Test func aNegativeManagedSpaceIDIsSkippedRatherThanFatal() throws {
    let layouts = SpaceService.parse([
        [
            "Display Identifier": "display",
            "Current Space": ["ManagedSpaceID": 1, "type": 0],
            "Spaces": [
                ["ManagedSpaceID": 1, "type": 0],
                ["ManagedSpaceID": -5, "type": 0],
                ["ManagedSpaceID": Int.min, "type": 0],
            ],
        ]
    ])

    let layout = try #require(layouts.first)
    #expect(layout.spaces == [SpaceIdentifier(1)])
}

/// And the same conversion on the "Current Space" path, which is a separate call
/// site and was fixed separately.
@Test func aNegativeCurrentSpaceIDYieldsNoLayoutRatherThanFatal() {
    let layouts = SpaceService.parse([
        [
            "Display Identifier": "display",
            "Current Space": ["ManagedSpaceID": -1, "type": 0],
            "Spaces": [["ManagedSpaceID": 1, "type": 0]],
        ]
    ])

    #expect(layouts.isEmpty)
}

/// `locate` keys on the window's OWN Space, not on the Space its display happens
/// to be showing.
///
/// A window can sit on a Space that is not currently visible. Moving it relative
/// to the visible Space would send it somewhere the user did not ask for: here the
/// display is showing Space 1, but the window is on Space 3, so "next" must be
/// computed from 3.
@Test func locateReportsTheWindowsOwnSpaceRatherThanTheVisibleOne() throws {
    let layouts = [
        SpaceLayout(
            displayIdentifier: "built-in",
            spaces: [SpaceIdentifier(1), SpaceIdentifier(3)],
            current: SpaceIdentifier(1))
    ]

    let found = try #require(SpaceService.locate(windowOn: [SpaceIdentifier(3)], in: layouts))
    #expect(found.current == SpaceIdentifier(3))
    #expect(found.display == "built-in")
}

/// The window is on the second display's strip, so that is the strip its
/// neighbour must be computed from — not the first display listed.
@Test func locateFindsTheWindowOnADisplayOtherThanTheFirst() throws {
    let layouts = [
        SpaceLayout(displayIdentifier: "built-in", spaces: [SpaceIdentifier(1)], current: SpaceIdentifier(1)),
        SpaceLayout(displayIdentifier: "external", spaces: [SpaceIdentifier(288)], current: SpaceIdentifier(288)),
    ]

    let found = try #require(SpaceService.locate(windowOn: [SpaceIdentifier(288)], in: layouts))
    #expect(found.display == "external")
    #expect(found.spaces == [SpaceIdentifier(288)])
}

/// A window assigned to all Desktops occupies every Space, so there is no single
/// right answer. Deterministic beats clever: the first display listed wins.
@Test func locatePicksTheFirstDisplayForAWindowAssignedToEverySpace() throws {
    let layouts = [
        SpaceLayout(displayIdentifier: "built-in", spaces: [SpaceIdentifier(1), SpaceIdentifier(3)], current: SpaceIdentifier(1)),
        SpaceLayout(displayIdentifier: "external", spaces: [SpaceIdentifier(288)], current: SpaceIdentifier(288)),
    ]

    let all = [SpaceIdentifier(1), SpaceIdentifier(3), SpaceIdentifier(288)]
    let found = try #require(SpaceService.locate(windowOn: all, in: layouts))
    #expect(found.display == "built-in")
}

/// A window the window server reports no Spaces for, and a window whose Space
/// belongs to no known display, both yield nothing rather than a guess. A guess
/// here means moving the window somewhere unpredictable.
@Test func locateYieldsNothingWhenTheWindowsSpaceCannotBePlaced() {
    let layouts = [
        SpaceLayout(displayIdentifier: "built-in", spaces: [SpaceIdentifier(1)], current: SpaceIdentifier(1))
    ]

    #expect(SpaceService.locate(windowOn: [], in: layouts) == nil)
    #expect(SpaceService.locate(windowOn: [SpaceIdentifier(999)], in: layouts) == nil)
    #expect(SpaceService.locate(windowOn: [SpaceIdentifier(1)], in: []) == nil)
}

/// A window on a full-screen application's Space cannot be placed, because such
/// Spaces are filtered out of every strip. The Spaces shortcuts then do nothing,
/// which is the intended outcome: moving a window out of a full-screen Space would
/// happen somewhere the user cannot see.
@Test func locateYieldsNothingForAWindowInsideAFullScreenSpace() {
    let layouts = SpaceService.parse([
        [
            "Display Identifier": "built-in",
            "Current Space": ["ManagedSpaceID": 398, "type": 4],
            "Spaces": [
                ["ManagedSpaceID": 1, "type": 0],
                ["ManagedSpaceID": 398, "type": 4],
            ],
        ]
    ])

    #expect(SpaceService.locate(windowOn: [SpaceIdentifier(398)], in: layouts) == nil)
}
