import Annotation
import CoreGraphics
import Foundation
import Testing
@testable import VideoEdit

// The bridge is where a gesture on the canvas becomes an edit to a timed
// document. The failure it exists to prevent is silent: a drag that edits the
// wrong annotation, or one at a different point in the video. So these tests
// mostly check identity -- that the thing that moved is the thing that was
// dragged, and that nothing else changed.

private func bridge(frames: Int = 300, fps: Double = 30) -> EditorBridge {
    EditorBridge(edit: RecordingEdit(videoURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                                     totalFrames: frames, fps: fps))
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 60, _ h: CGFloat = 40)
    -> Annotation {
    Annotation(kind: .rect(origin: CGPoint(x: x, y: y), size: CGSize(width: w, height: h)))
}

/// Drag a rectangle from one point to another, the way the view does.
private func drawRect(_ b: inout EditorBridge, from: CGPoint, to: CGPoint) {
    b.editor.select(tool: .rectangle)
    _ = b.pointerDown(at: from)
    _ = b.pointerDragged(to: to)
    b.pointerUp(at: to)
}

// MARK: Creating

@Test func aShapeDrawnOnTheCanvasEntersTheDocument() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))

    #expect(b.edit.annotations.count == 1)
    #expect(b.edit.annotations[0].range.start == 100,
            "a new shape starts at the playhead, not at zero")
}

@Test func aShapeDrawnAtOneFrameIsNotVisibleAtAnother() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    #expect(b.editor.annotations.count == 1)

    b.seek(to: 250)
    #expect(b.editor.annotations.isEmpty,
            "the canvas still shows a shape that has ended")
}

@Test func movingThePlayheadBackBringsTheShapeBack() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.seek(to: 250)
    b.seek(to: 110)
    #expect(b.editor.annotations.count == 1)
    #expect(b.edit.annotations.count == 1, "and it was not duplicated on the way")
}

@Test func reloadingDoesNotDuplicateAnnotations() {
    // The bridge reloads on every seek; if sync treated the reloaded entries as
    // new, the document would grow every time the playhead moved.
    var b = bridge()
    b.seek(to: 50)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    for frame in [55, 60, 55, 51, 60] { b.seek(to: frame) }
    #expect(b.edit.annotations.count == 1)
}

@Test func aTinyClickCreatesNothing() {
    var b = bridge()
    b.seek(to: 10)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11))
    #expect(b.edit.annotations.isEmpty)
}

// MARK: Editing an existing shape

@Test func draggingAShapeMovesThatShapeAndOnlyThatShape() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    drawRect(&b, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 280, y: 260))
    let untouchedBefore = b.edit.annotations[0].annotation

    // Grab the second one and move it.
    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 240, y: 230))
    _ = b.pointerDragged(to: CGPoint(x: 260, y: 250))
    b.pointerUp(at: CGPoint(x: 260, y: 250))

    #expect(b.edit.annotations.count == 2, "moving must not create anything")
    #expect(b.edit.annotations[0].annotation == untouchedBefore,
            "the wrong annotation was edited")
    #expect(b.edit.annotations[1].annotation != untouchedBefore)
}

@Test func editingAShapeLeavesItsLifespanAlone() {
    // A move is a change of shape, not of timing. Retiming on every drag would
    // quietly undo the user's timeline work.
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.setSelectedRange(start: 100, end: 280)
    let range = b.edit.annotations[0].range

    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 50, y: 40))
    _ = b.pointerDragged(to: CGPoint(x: 70, y: 60))
    b.pointerUp(at: CGPoint(x: 70, y: 60))

    #expect(b.edit.annotations[0].range == range)
}

@Test func aShapeEditedAtALaterFrameKeepsItsOriginalStart() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.setSelectedRange(start: 100, end: 200)

    // Scrub into the middle of its life and nudge it.
    b.seek(to: 150)
    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 50, y: 40))
    _ = b.pointerDragged(to: CGPoint(x: 55, y: 45))
    b.pointerUp(at: CGPoint(x: 55, y: 45))

    #expect(b.edit.annotations.count == 1, "editing mid-life must not fork a copy")
    #expect(b.edit.annotations[0].range.start == 100)
}

// MARK: Deleting

@Test func deletingRemovesItFromTheWholeVideoNotJustThisFrame() {
    // Removing it only from the editor's list would drop it from this frame and
    // leave it in the document, so it would reappear on the next seek.
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 50, y: 40))
    b.deleteSelected()

    #expect(b.edit.annotations.isEmpty)
    b.seek(to: 105)
    #expect(b.editor.annotations.isEmpty, "the deleted annotation came back")
}

@Test func deletingWithNothingSelectedDoesNothing() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.editor.clearSelection()
    b.sync()
    b.deleteSelected()
    #expect(b.edit.annotations.count == 1)
}

@Test func deletingTheFirstOfTwoLeavesTheOther() {
    // The mapping is rebuilt after a delete; if it were not, the surviving
    // annotation would be edited through a stale index.
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    drawRect(&b, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 280, y: 260))
    let survivor = b.edit.annotations[1].annotation

    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 50, y: 40))
    b.deleteSelected()

    #expect(b.edit.annotations.count == 1)
    #expect(b.edit.annotations[0].annotation == survivor)

    // And the survivor is still editable through the rebuilt mapping.
    _ = b.pointerDown(at: CGPoint(x: 240, y: 230))
    _ = b.pointerDragged(to: CGPoint(x: 250, y: 240))
    b.pointerUp(at: CGPoint(x: 250, y: 240))
    #expect(b.edit.annotations.count == 1)
    #expect(b.edit.annotations[0].annotation != survivor, "the move did not take effect")
}

// MARK: Selection

@Test func selectionSurvivesASeekWithinTheAnnotationsLife() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.setSelectedRange(start: 100, end: 200)
    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 50, y: 40))
    #expect(b.selectedDocumentIndex == 0)

    b.seek(to: 150)
    #expect(b.selectedDocumentIndex == 0, "the selection was lost by scrubbing")
    #expect(b.editor.selected != nil, "and the canvas no longer shows it selected")
}

@Test func theSelectedTimedAnnotationCarriesItsTiming() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    #expect(b.selectedTimed?.range.start == 100)
}

@Test func clickingEmptySpaceClearsTheDocumentSelection() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.editor.select(tool: .select)
    _ = b.pointerDown(at: CGPoint(x: 500, y: 500))
    b.pointerUp(at: CGPoint(x: 500, y: 500))
    #expect(b.selectedDocumentIndex == nil)
}

// MARK: Style and tool survive reloads

@Test func theToolAndStyleSurviveScrubbing() {
    // Reloading rebuilds the editor, so anything the toolbar shows has to be
    // carried across or the UI and the editor drift apart.
    var b = bridge()
    b.editor.select(tool: .ellipse)
    b.editor.style.color = AnnotationColor.choices[3]
    b.editor.style.width = 9

    b.seek(to: 120)
    #expect(b.editor.tool == .ellipse)
    #expect(b.editor.style.color == AnnotationColor.choices[3])
    #expect(b.editor.style.width == 9)
}

// MARK: Document-level operations

@Test func retimingTheSelectionTakesEffect() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.setSelectedRange(start: 50, end: 250)
    #expect(b.edit.annotations[0].range == FrameRange(start: 50, end: 250))
}

@Test func aPulseCanBeToggledOnTheSelection() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.toggleSelectedPulse()
    #expect(b.edit.annotations[0].pulses)
}

@Test func insertingAFreezeThroughTheBridgeShiftsAnnotationsAndReloads() {
    var b = bridge()
    b.seek(to: 200)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.seek(to: 50)
    b.insertFreeze(at: 50, holdFrames: 30)
    #expect(b.edit.annotations[0].range.start == 230)
    #expect(b.edit.totalFrames == 330)
}

@Test func changingSpeedThroughTheBridgeReloadsTheCanvas() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.setPlaybackSpeed(2)
    // The annotation moved to frame 50, and the playhead followed it, so it is
    // still on screen.
    #expect(b.edit.annotations[0].range.start == 50)
    #expect(b.editor.annotations.count == 1,
            "after a speed change the canvas lost the annotation under the playhead")
}

@Test func undoIsOneHistoryNotTwo() {
    // The editor has its own undo stack covering the current frame's list, which
    // cannot take back a freeze. Undo has to be the document's.
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.undo()
    #expect(b.edit.annotations.isEmpty)
    #expect(b.editor.annotations.isEmpty, "the canvas still shows the undone shape")
    b.redo()
    #expect(b.edit.annotations.count == 1)
}

// MARK: Playback

@Test func advancingMovesThePlayheadAndReloads() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.setSelectedRange(start: 100, end: 102)

    b.seek(to: 101)
    #expect(b.editor.annotations.count == 1)
    let moved = b.advance()
    #expect(moved)
    #expect(b.editor.annotations.isEmpty, "the annotation outstayed its range at 102")
}

@Test func advancingStopsAtTheEnd() {
    var b = bridge(frames: 3)
    b.seek(to: 2)
    let moved = b.advance()
    #expect(!moved)
}

// MARK: Drawing lists

@Test func theDraftIsDrawnBeforeItIsCommitted() {
    // Without this the shape is invisible until the mouse comes up, so the user
    // is dragging out something they cannot see.
    var b = bridge()
    b.seek(to: 100)
    b.editor.select(tool: .rectangle)
    _ = b.pointerDown(at: CGPoint(x: 10, y: 10))
    _ = b.pointerDragged(to: CGPoint(x: 90, y: 70))
    #expect(b.timedRenderList().count == 1)
    #expect(b.edit.annotations.isEmpty, "and it is not in the document yet")
}

@Test func theRenderListCarriesPulseFlags() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.toggleSelectedPulse()
    #expect(b.timedRenderList().first?.pulses ?? false)
}

@Test func theRenderListOnlyHoldsWhatIsAlive() {
    var b = bridge()
    b.seek(to: 100)
    drawRect(&b, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 70))
    b.seek(to: 280)
    #expect(b.timedRenderList().isEmpty)
}
