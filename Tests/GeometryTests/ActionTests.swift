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
    #expect(!Action.display(.above).isPlacement)
    // The capture actions (ClipShot) have no window frame at all; they are
    // routing identifiers dispatched to the capture session, not placements.
    #expect(!Action.captureScreenshot.isPlacement)
    #expect(!Action.startRecording.isPlacement)
}

@Test func captureActionsDoNotCycle() {
    // Only halves cycle. A repeated capture press must behave like the Rust
    // ClipShot did: start (or stop) — never advance through a size cycle.
    #expect(!Action.captureScreenshot.cycles)
    #expect(!Action.startRecording.cycles)
}
