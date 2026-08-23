import CoreGraphics
import Testing
@testable import Annotation

// The editor is a pure state machine, so every editing rule is testable here —
// no window, no screenshot, no permissions.

private func drag(_ editor: inout Editor, from a: CGPoint, to b: CGPoint) {
    editor.pointerDown(at: a)
    editor.pointerDragged(to: b)
    editor.pointerUp(at: b)
}

private let p10 = CGPoint(x: 10, y: 10)
private let p90 = CGPoint(x: 90, y: 90)

// MARK: Creating

@Test func eachDrawingToolCreatesItsOwnKind() {
    let expected: [(Tool, String)] = [
        (.arrow, "arrow"), (.rectangle, "rect"), (.ellipse, "ellipse"),
        (.pencil, "pencil"), (.highlight, "highlight"), (.blur, "blur"),
    ]
    for (tool, name) in expected {
        var editor = Editor()
        editor.select(tool: tool)
        drag(&editor, from: p10, to: p90)
        #expect(editor.annotations.count == 1, "\(name): expected one annotation")
        let kindName = String(describing: editor.annotations[0].kind).prefix(name.count)
        #expect(kindName == name, "\(name): got \(kindName)")
    }
}

@Test func aStepIsPlacedByClickingNotDragging() {
    var editor = Editor()
    editor.select(tool: .step)
    editor.pointerDown(at: p10)
    #expect(editor.annotations.count == 1)
    editor.pointerUp(at: p10)
    #expect(editor.annotations.count == 1, "a step must not also commit a dragged shape")
    if case let .step(center, radius) = editor.annotations[0].kind {
        #expect(center == p10)
        #expect(radius == AnnotationStyle.stepRadius)
    } else {
        Issue.record("expected a step")
    }
}

@Test func newShapesTakeTheCurrentStyle() {
    var editor = Editor()
    editor.style.color = AnnotationColor.choices[4]
    editor.style.width = AnnotationStyle.strokeThick
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: p90)
    #expect(editor.annotations[0].color == AnnotationColor.choices[4])
    #expect(editor.annotations[0].width == AnnotationStyle.strokeThick)
}

@Test func aStrayClickLeavesNothingBehind() {
    // Without this, a click with a shape tool commits a zero-size annotation
    // whose bounding rect is empty — so it can never be selected or deleted,
    // and it is invisible. It would be a permanent, unremovable artifact.
    for tool: Tool in [.arrow, .rectangle, .ellipse, .pencil, .highlight, .blur, .callout] {
        var editor = Editor()
        editor.select(tool: tool)
        drag(&editor, from: p10, to: p10)
        #expect(editor.annotations.isEmpty, "\(tool) kept a zero-size shape")
        #expect(editor.draft == nil)
    }
}

@Test func theDraftIsVisibleWhileDraggingAndGoneAfter() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    editor.pointerDown(at: p10)
    editor.pointerDragged(to: p90)
    #expect(editor.annotations.isEmpty, "nothing is committed mid-drag")
    #expect(editor.renderList.count == 1, "the draft has to be drawn or the drag is invisible")
    editor.pointerUp(at: p90)
    #expect(editor.annotations.count == 1)
    #expect(editor.renderList.count == 1)
}

// MARK: Selecting, moving, resizing

@Test func clickingSelectsTheTopmostShape() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: p90)                                    // 0: underneath
    drag(&editor, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80)) // 1: on top

    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 50, y: 50))
    #expect(editor.selected == 1, "the shape drawn last must win the click")
}

@Test func clickingEmptySpaceClearsTheSelectionAndDoesNotConsumeTheEvent() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 40, y: 40))
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 20, y: 20))
    #expect(editor.selected == 0)

    // Not consuming it is what lets a click outside every shape fall through
    // to the region-selection drag underneath.
    let consumed = editor.pointerDown(at: CGPoint(x: 300, y: 300))
    #expect(!consumed)
    #expect(editor.selected == nil)
}

@Test func draggingASelectedShapeMovesIt() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 50, y: 50))
    let before = editor.annotations[0].boundingRect()

    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 30, y: 30))
    editor.pointerDragged(to: CGPoint(x: 60, y: 40))
    editor.pointerUp(at: CGPoint(x: 60, y: 40))

    let after = editor.annotations[0].boundingRect()
    #expect(after.origin.x == before.origin.x + 30)
    #expect(after.origin.y == before.origin.y + 10)
    #expect(after.size == before.size, "a move must not resize")
}

@Test func draggingAHandleResizesRatherThanMoves() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 50, y: 50))
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 30, y: 30))    // select it
    #expect(editor.selected == 0)

    // Grab the bottom-right handle and pull it out.
    let handles = editor.annotations[0].resizeHandles()
    let corner = handles.first { $0.0 == .bottomRight }!.1
    editor.pointerDown(at: corner)
    editor.pointerDragged(to: CGPoint(x: 90, y: 90))
    editor.pointerUp(at: CGPoint(x: 90, y: 90))

    // Inspect the stored geometry: boundingRect() is padded for hit-testing,
    // so it is the wrong ruler for "did the origin move".
    guard case let .rect(origin, size) = editor.annotations[0].kind else {
        Issue.record("expected a rect"); return
    }
    #expect(origin.x + size.width > 85 && origin.y + size.height > 85,
            "the corner should have followed the pointer")
    #expect(origin == CGPoint(x: 10, y: 10), "the opposite corner must stay put")
}

@Test func resizingInsideOutNormalizesSoHandlesStayUsable() {
    // Drag the bottom-right handle up past the top-left. The shape keeps
    // drawing fine either way, but if the negative size is left in place the
    // handles are computed from it and land on the wrong corners.
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 90))
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 70, y: 70))
    let corner = editor.annotations[0].resizeHandles().first { $0.0 == .bottomRight }!.1
    editor.pointerDown(at: corner)
    editor.pointerDragged(to: CGPoint(x: 20, y: 20))
    editor.pointerUp(at: CGPoint(x: 20, y: 20))

    if case let .rect(_, size) = editor.annotations[0].kind {
        #expect(size.width > 0 && size.height > 0, "size stayed negative: \(size)")
    } else {
        Issue.record("expected a rect")
    }
}

@Test func selectingAShapeAdoptsItsStyleIntoTheToolbar() {
    // So the toolbar shows what the selected shape actually is, and a nudge of
    // one control does not silently restyle everything else about it.
    var editor = Editor()
    editor.style.color = AnnotationColor.choices[2]
    editor.style.width = AnnotationStyle.strokeThick
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 50, y: 50))

    editor.style.color = AnnotationColor.choices[7]
    editor.style.width = AnnotationStyle.strokeThin
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 30, y: 30))
    #expect(editor.style.color == AnnotationColor.choices[2])
    #expect(editor.style.width == AnnotationStyle.strokeThick)
}

@Test func restylingAppliesToTheSelectedShape() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 50, y: 50))
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 30, y: 30))

    editor.style.color = AnnotationColor.choices[5]
    editor.applyStyleToSelection()
    #expect(editor.annotations[0].color == AnnotationColor.choices[5])
}

@Test func switchingToADrawingToolDropsTheSelection() {
    // Otherwise the old shape's handles stay live and steal the first drag of
    // the new tool.
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 50, y: 50))
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 30, y: 30))
    #expect(editor.selected == 0)
    editor.select(tool: .ellipse)
    #expect(editor.selected == nil)
}

// MARK: Undo

@Test func undoRestoresWhatChangedNotJustTheLastShape() {
    // Rust's undo pops the newest annotation, so after moving a shape ⌘Z
    // deletes an unrelated one and the move stands. Snapshots fix that.
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 40, y: 40))   // shape A
    drag(&editor, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 90, y: 90)) // shape B
    #expect(editor.annotations.count == 2)

    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 20, y: 20))         // select A
    let originalA = editor.annotations[0].boundingRect()
    editor.pointerDragged(to: CGPoint(x: 30, y: 30))      // move it
    editor.pointerUp(at: CGPoint(x: 30, y: 30))
    #expect(editor.annotations[0].boundingRect().origin != originalA.origin)

    editor.undo()
    #expect(editor.annotations.count == 2, "undo of a move must not delete a shape")
    #expect(editor.annotations[0].boundingRect().origin == originalA.origin)
}

@Test func undoAndRedoWalkTheHistoryBothWays() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 40, y: 40))
    drag(&editor, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 80, y: 80))
    #expect(editor.annotations.count == 2)

    editor.undo()
    #expect(editor.annotations.count == 1)
    editor.undo()
    #expect(editor.annotations.isEmpty)
    #expect(!editor.canUndo)

    editor.redo()
    #expect(editor.annotations.count == 1)
    editor.redo()
    #expect(editor.annotations.count == 2)
    #expect(!editor.canRedo)
}

@Test func aNewEditReplacesTheRedoBranch() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 40, y: 40))
    drag(&editor, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 80, y: 80))
    editor.undo()
    #expect(editor.canRedo)

    drag(&editor, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 90, y: 40))
    #expect(!editor.canRedo, "drawing after an undo must not leave a stale redo")
    #expect(editor.annotations.count == 2)
}

@Test func deleteIsUndoable() {
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: CGPoint(x: 50, y: 50))
    editor.select(tool: .select)
    editor.pointerDown(at: CGPoint(x: 30, y: 30))
    editor.deleteSelected()
    #expect(editor.annotations.isEmpty)
    #expect(editor.selected == nil)
    editor.undo()
    #expect(editor.annotations.count == 1)
}

@Test func undoWithNoHistoryIsHarmless() {
    var editor = Editor()
    editor.undo()
    editor.redo()
    #expect(editor.annotations.isEmpty)
}

// MARK: Text

@Test func aTextToolClickOpensTypingAndAnEmptyLabelIsDiscarded() {
    var editor = Editor()
    editor.select(tool: .text)
    editor.pointerDown(at: p10)
    #expect(editor.editingText == 0)
    #expect(editor.annotations.count == 1)

    // Typing nothing and clicking away must not leave an invisible annotation.
    editor.endTextEditing()
    #expect(editor.annotations.isEmpty)
    #expect(!editor.canUndo, "an abandoned empty label is not an undo step")
}

@Test func typedTextIsStoredAndKept() {
    var editor = Editor()
    editor.select(tool: .text)
    editor.pointerDown(at: p10)
    editor.setEditingText("hello")
    editor.endTextEditing()
    #expect(editor.annotations.count == 1)
    if case let .text(_, text) = editor.annotations[0].kind {
        #expect(text == "hello")
    } else {
        Issue.record("expected text")
    }
}

@Test func aCalloutDragOpensTypingOnCommit() {
    var editor = Editor()
    editor.select(tool: .callout)
    editor.pointerDown(at: CGPoint(x: 100, y: 100))
    editor.pointerDragged(to: CGPoint(x: 200, y: 200))
    editor.pointerUp(at: CGPoint(x: 200, y: 200))
    #expect(editor.annotations.count == 1)
    #expect(editor.editingText == 0, "a callout with no text is useless, so typing starts at once")
    editor.setEditingText("note")
    editor.endTextEditing()
    if case let .callout(_, _, _, text) = editor.annotations[0].kind {
        #expect(text == "note")
    } else {
        Issue.record("expected a callout")
    }
}

// MARK: Crop

@Test func aCropDragReportsItsRectOnce() {
    var editor = Editor()
    editor.select(tool: .crop)
    editor.pointerDown(at: CGPoint(x: 20, y: 30))
    editor.pointerDragged(to: CGPoint(x: 120, y: 130))
    #expect(editor.cropDraft == CGRect(x: 20, y: 30, width: 100, height: 100))
    let committed = editor.pointerUp(at: CGPoint(x: 120, y: 130))
    #expect(committed == CGRect(x: 20, y: 30, width: 100, height: 100))
    #expect(editor.cropDraft == nil)
}

@Test func aCropDraggedBackwardsStillNormalizes() {
    var editor = Editor()
    editor.select(tool: .crop)
    editor.pointerDown(at: CGPoint(x: 120, y: 130))
    editor.pointerDragged(to: CGPoint(x: 20, y: 30))
    let committed = editor.pointerUp(at: CGPoint(x: 20, y: 30))
    #expect(committed == CGRect(x: 20, y: 30, width: 100, height: 100))
}

@Test func aCropClickIsIgnored() {
    var editor = Editor()
    editor.select(tool: .crop)
    editor.pointerDown(at: p10)
    #expect(editor.pointerUp(at: p10) == nil, "cropping to nothing is never intended")
}

// MARK: Reset

@Test func resetClearsEverythingIncludingHistory() {
    // The overlay reuses one editor across captures; leaking the last
    // capture's shapes or undo stack into the next one would be a bad surprise.
    var editor = Editor()
    editor.select(tool: .rectangle)
    drag(&editor, from: p10, to: p90)
    editor.reset()
    #expect(editor.annotations.isEmpty)
    #expect(!editor.canUndo)
    #expect(!editor.canRedo)
    #expect(editor.selected == nil)
    #expect(editor.tool == .select)
}
