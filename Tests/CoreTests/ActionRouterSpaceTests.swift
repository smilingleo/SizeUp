import CoreGraphics
import Geometry
import Testing
import WindowKit
@testable import Core

// Fixtures (builtIn, TestWindow, makeRouter, FakeSpaceControlling) live in
// RouterFixtures.swift.

private let spaceOne = SpaceIdentifier(1)
private let spaceTwo = SpaceIdentifier(2)
private let spaceThree = SpaceIdentifier(3)

@MainActor
@Test func movesTheFocusedWindowToTheNextSpace() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo, spaceThree], current: spaceOne, display: "1")

    makeRouter(window: window, spaces: fake).perform(.space(.next))

    #expect(fake.moves.map(\.space) == [spaceTwo])
    #expect(fake.moves.map(\.windowID) == [42])
}

@MainActor
@Test func followsTheWindowToTheDestinationSpaceWhenEnabled() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")

    makeRouter(window: window, spaces: fake, followsWindowToSpace: true).perform(.space(.next))

    #expect(fake.activations.map(\.space) == [spaceTwo])
    #expect(fake.activations.map(\.display) == ["1"])
}

@MainActor
@Test func doesNotFollowWhenFollowingIsDisabled() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")

    makeRouter(window: window, spaces: fake, followsWindowToSpace: false).perform(.space(.next))

    #expect(fake.moves.count == 1)
    #expect(fake.activations.isEmpty)
}

/// Following to a Space the window did not reach would leave the user
/// staring at an empty Space, so a failed move must never be followed even
/// when following is enabled.
@MainActor
@Test func doesNotFollowWhenTheMoveFails() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")
    fake.moveSucceeds = false

    makeRouter(window: window, spaces: fake, followsWindowToSpace: true).perform(.space(.next))

    #expect(fake.moves.count == 1)
    #expect(fake.activations.isEmpty)
}

@MainActor
@Test func doesNothingWhenSpaceControllingIsUnavailable() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    fake.isAvailable = false
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")

    makeRouter(window: window, spaces: fake).perform(.space(.next))

    #expect(fake.moves.isEmpty)
}

@MainActor
@Test func doesNothingWhenNoSpaceControllingWasInjected() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)

    // Must not crash: a machine where the private API is unavailable has no
    // `SpaceControlling` injected at all.
    makeRouter(window: window, spaces: nil).perform(.space(.next))
}

@MainActor
@Test func doesNothingWhenTheWindowHasNoWindowID() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: nil)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")

    makeRouter(window: window, spaces: fake).perform(.space(.next))

    #expect(fake.moves.isEmpty)
}

@MainActor
@Test func doesNothingWhenNoLayoutIsFoundForTheWindow() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 99)
    let fake = FakeSpaceControlling()
    // No entry for windowID 99.

    makeRouter(window: window, spaces: fake).perform(.space(.next))

    #expect(fake.moves.isEmpty)
    #expect(fake.activations.isEmpty)
}

@MainActor
@Test func doesNothingWhenThereIsNoNeighbouringSpace() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    // A single-space display has no neighbour in either direction.
    fake.layoutsByWindow[42] = (spaces: [spaceOne], current: spaceOne, display: "1")

    makeRouter(window: window, spaces: fake).perform(.space(.next))

    #expect(fake.moves.isEmpty)
}

/// The load-bearing test: the window's frame does not change on a Space
/// move, so recording a placement or advancing the cycle would corrupt Snap
/// Back and the size cycle for an action that never touched the frame.
@MainActor
@Test func spaceMoveDoesNotRecordAPlacementOrDisturbSnapBack() {
    let original = CGRect(x: 250, y: 175, width: 900, height: 700)
    let window = TestWindow(frame: original, windowID: 42)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")
    let store = WindowStateStore()
    let router = makeRouter(window: window, store: store, spaces: fake)

    router.perform(.half(.left))
    let placedFrame = window.stored
    window.windowID = 42

    router.perform(.space(.next))

    // Snap Back must still restore the frame from before the PLACEMENT, not
    // whatever a (nonexistent) recording of the space move might have held.
    router.perform(.snapBack)
    #expect(window.stored == original)
    #expect(window.stored != placedFrame)
}

/// Same pin as above, from a different angle: the store's cycle position
/// must be untouched by a Space move, so the next placement press still
/// behaves as a first press rather than an advance.
@MainActor
@Test func spaceMoveDoesNotAdvanceTheSizeCycle() {
    let window = TestWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600), windowID: 42)
    let fake = FakeSpaceControlling()
    fake.layoutsByWindow[42] = (spaces: [spaceOne, spaceTwo], current: spaceOne, display: "1")
    let store = WindowStateStore()
    let router = makeRouter(
        window: window, spans: [.half, Span(occupied: 1, of: 3)], store: store, spaces: fake
    )

    router.perform(.half(.left))
    #expect(store.retainedPlacement(for: window.key, currentFrame: window.stored)?.step == 0)

    router.perform(.space(.next))

    let retained = store.retainedPlacement(for: window.key, currentFrame: window.stored)
    #expect(retained?.step == 0)
    #expect(retained?.action == .half(.left))
}
