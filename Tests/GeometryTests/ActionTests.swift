import Testing
@testable import Geometry

@Test func placementActionsAreRecomputableOnAnotherDisplay() {
    #expect(Action.half(.left).isPlacement)
    #expect(Action.quarter(.upperRight).isPlacement)
    #expect(Action.center.isPlacement)
    #expect(Action.fullScreen.isPlacement)
}

@Test func nonPlacementActionsAreNotRecomputable() {
    // Recomputing these on another display is meaningless: `snapBack` restores
    // a remembered frame, and the moves describe a transition, not a layout.
    #expect(!Action.snapBack.isPlacement)
    #expect(!Action.display(.next).isPlacement)
    #expect(!Action.space(.above).isPlacement)
}
