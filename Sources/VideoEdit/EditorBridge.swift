import Annotation
import CoreGraphics
import Foundation

/// Connects C2's `Editor` to the recording's timed annotations.
///
/// The screenshot editor works on one flat list of shapes. The recording editor
/// needs the same gestures — draft, select, move, resize, handles, text, pencil,
/// callout — but each shape belongs to a span of frames, and only the shapes
/// alive at the playhead are on screen.
///
/// Rather than reimplement any of that, the bridge loads the annotations visible
/// at the current frame into a plain `Editor`, lets it handle the gesture, and
/// writes the result back. The only real work is keeping track of which entry in
/// the editor's list is which entry in the document, which is what `mapping` is
/// for — get that wrong and a drag silently edits a different annotation, at a
/// different point in the video.
///
/// Pure and AppKit-free on purpose: this is where the off-by-one lives, so it
/// has to be testable without a window.
public struct EditorBridge {
    public private(set) var edit: RecordingEdit
    /// The gesture machine, driven by the view.
    public var editor = Editor()
    /// `mapping[i]` is the index in `edit.annotations` of `editor.annotations[i]`.
    private var mapping: [Int] = []
    /// The frame `mapping` was built for.
    public private(set) var loadedFrame: Int = -1

    public init(edit: RecordingEdit) {
        self.edit = edit
        reload()
    }

    /// The playhead. Setting it reloads what the editor can touch.
    public var currentFrame: Int { edit.currentFrame }

    public mutating func seek(to frame: Int) {
        guard frame != edit.currentFrame else { return }
        // Finish any half-typed label first: moving the playhead away while a
        // text caret is live would abandon the text with no way back to it.
        commitText()
        edit.seek(to: frame)
        reload()
    }

    /// Rebuild the editor's list from the annotations visible at the playhead.
    ///
    /// Style is preserved across the reload: the toolbar shows it, and having the
    /// colour reset every time the playhead moved would be baffling.
    public mutating func reload() {
        let style = editor.style
        let tool = editor.tool
        let visible = edit.annotations(at: edit.currentFrame)
        editor.reset()
        editor.style = style
        editor.select(tool: tool)
        mapping = visible.map(\.index)
        for entry in visible { editor.appendWithoutCheckpoint(entry.annotation) }
        loadedFrame = edit.currentFrame
        // Keep the document's selection showing if it is on screen.
        if let selected = edit.selected,
           let position = mapping.firstIndex(of: selected) {
            editor.selectAnnotation(at: position)
        }
    }

    /// Write the editor's list back into the document.
    ///
    /// Called after every gesture. Entries beyond `mapping` are new shapes and
    /// get a lifespan starting at the playhead; entries within it are edits to
    /// shapes that already had one, so their lifespan is left alone.
    public mutating func sync() {
        let list = editor.annotations

        // A removal inside the editor (delete key, or its own undo) shows up as a
        // shorter list. Matching by position is not enough to tell *which* went,
        // so the view routes deletion through `deleteSelected()` instead and this
        // path only has to avoid corrupting the mapping.
        if list.count < mapping.count {
            reload()
            return
        }

        for (position, annotation) in list.enumerated() {
            if position < mapping.count {
                edit.update(mapping[position], annotation: annotation)
            } else {
                let index = edit.add(annotation, at: edit.currentFrame)
                mapping.append(index)
            }
        }
        // Mirror the editor's selection onto the document, so the timeline and
        // the range controls act on what the canvas shows as selected.
        if let position = editor.selected, mapping.indices.contains(position) {
            edit.select(mapping[position])
        } else {
            edit.select(nil)
        }
    }

    /// The document index of the selected annotation, if any.
    public var selectedDocumentIndex: Int? {
        guard let position = editor.selected, mapping.indices.contains(position) else {
            return nil
        }
        return mapping[position]
    }

    /// The timed annotation the user has selected, if any.
    public var selectedTimed: TimedAnnotation? {
        selectedDocumentIndex.flatMap {
            edit.annotations.indices.contains($0) ? edit.annotations[$0] : nil
        }
    }

    // MARK: Gestures, forwarded and then synced

    public mutating func pointerDown(at point: CGPoint) -> Bool {
        let handled = editor.pointerDown(at: point)
        if handled { sync() }
        return handled
    }

    public mutating func pointerDragged(to point: CGPoint) -> Bool {
        editor.pointerDragged(to: point)
    }

    @discardableResult
    public mutating func pointerUp(at point: CGPoint) -> CGRect? {
        let crop = editor.pointerUp(at: point)
        sync()
        return crop
    }

    public mutating func setEditingText(_ text: String) {
        editor.setEditingText(text)
        sync()
    }

    public mutating func commitText() {
        guard editor.editingText != nil else { return }
        editor.endTextEditing()
        sync()
    }

    /// Select by document index — what the timeline clicks with, since it draws
    /// spans from the document rather than from the current frame's list.
    ///
    /// Moves the playhead into the annotation's life when it is outside it: the
    /// alternative is selecting something the canvas cannot show, which looks
    /// like the click did nothing.
    public mutating func selectDocument(_ index: Int?, seekIntoRange: Bool = false) {
        guard let index, edit.annotations.indices.contains(index) else {
            edit.select(nil)
            reload()
            return
        }
        if seekIntoRange, !edit.annotations[index].range.contains(edit.currentFrame) {
            commitText()
            edit.seek(to: edit.annotations[index].range.start)
        }
        edit.select(index)
        reload()
    }

    /// Delete the selected annotation from the document, not just from the frame.
    ///
    /// Deleting only from the editor's list would drop it from this frame and
    /// leave it in the document, so it would reappear as soon as the playhead
    /// moved.
    public mutating func deleteSelected() {
        guard let index = selectedDocumentIndex else { return }
        edit.remove(index)
        reload()
    }

    // MARK: Document-level edits

    /// Retime the selected annotation.
    public mutating func setSelectedRange(start: Int, end: Int?) {
        guard let index = selectedDocumentIndex else { return }
        edit.setRange(index, start: start, end: end)
        reload()
    }

    public mutating func toggleSelectedPulse() {
        guard let index = selectedDocumentIndex else { return }
        edit.togglePulse(index)
    }

    public mutating func insertFreeze(at frame: Int, holdFrames: Int) {
        commitText()
        edit.insertFreeze(at: frame, holdFrames: holdFrames)
        reload()
    }

    public mutating func removeFreeze(at frame: Int) {
        commitText()
        _ = edit.removeFreeze(at: frame)
        reload()
    }

    public mutating func setPlaybackSpeed(_ speed: Double) {
        commitText()
        edit.setPlaybackSpeed(speed)
        reload()
    }

    /// Undo at the document level.
    ///
    /// The editor's own undo stack only covers the current frame's list, so it
    /// cannot take back a freeze or a retime. Routing undo through the document
    /// keeps one history instead of two that disagree.
    public mutating func undo() {
        commitText()
        edit.undo()
        reload()
    }

    public mutating func redo() {
        commitText()
        _ = edit.redo()
        reload()
    }

    public var isPlaying: Bool {
        get { edit.isPlaying }
        set { edit.isPlaying = newValue }
    }

    /// Advance during playback. Returns false at the end.
    public mutating func advance() -> Bool {
        let moved = edit.advance()
        if moved { reload() }
        return moved
    }

    /// Everything to draw at the playhead, including the live draft.
    public var renderList: [Annotation] { editor.renderList }

    /// The visible annotations with their pulse flags, for drawing.
    public func timedRenderList() -> [TimedAnnotation] {
        var list = edit.annotations.filter { $0.range.contains(edit.currentFrame) }
        // The draft is not in the document yet, so it has no lifespan; show it
        // for this frame only.
        if let draft = editor.draft {
            list.append(TimedAnnotation(
                annotation: draft,
                range: FrameRange(start: edit.currentFrame, end: edit.currentFrame + 1)))
        }
        return list
    }
}
