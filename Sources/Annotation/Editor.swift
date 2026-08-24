import CoreGraphics
import Foundation

/// The style new annotations are created with — what the toolbar's colour
/// swatches, stroke buttons and font stepper mutate.
public struct EditorStyle: Equatable, Sendable {
    public var color: AnnotationColor
    public var width: CGFloat
    public var fontSize: CGFloat
    public var opacity: CGFloat

    public init(
        color: AnnotationColor = AnnotationColor.choices[0],
        width: CGFloat = AnnotationStyle.strokeMedium,
        fontSize: CGFloat = AnnotationStyle.defaultFontSize,
        opacity: CGFloat = 1
    ) {
        self.color = color
        self.width = width
        self.fontSize = fontSize
        self.opacity = opacity
    }
}

/// The annotation editor's state and behaviour, with no window attached.
///
/// Every editing rule lives here — which tool creates what, what a drag does,
/// what undo means — so all of it is testable without putting a window on a
/// screen. The view above it only translates events and draws.
///
/// Undo is a snapshot stack, not Rust's "pop the last annotation". Popping
/// cannot undo a move, a resize, a style change or a delete, so in the Rust app
/// ⌘Z after dragging a shape deletes an unrelated one. Snapshots cost a few
/// hundred bytes per edit and make undo mean what the user expects.
public struct Editor {
    /// A drag that a click has started.
    enum Drag: Equatable {
        case none
        /// Creating a new shape.
        case creating(from: CGPoint)
        /// Moving the selected annotation; the offset from its origin.
        case moving(from: CGPoint)
        /// Resizing the selected annotation by a handle.
        case resizing(HandleKind)
        /// Dragging out a new crop rect.
        case cropping(from: CGPoint)
    }

    public private(set) var annotations: [Annotation] = []
    public var style = EditorStyle()
    public private(set) var tool: Tool = .select
    public private(set) var selected: Int?
    /// The shape being dragged out, not yet committed.
    public private(set) var draft: Annotation?
    /// The crop rect a crop drag is proposing, in view points.
    public private(set) var cropDraft: CGRect?
    /// The index of the annotation whose text is being typed into, if any.
    public private(set) var editingText: Int?

    private(set) var drag: Drag = .none
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    public init() {}

    /// Everything to draw, in order: committed shapes then the live draft.
    public var renderList: [Annotation] {
        draft.map { annotations + [$0] } ?? annotations
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var selectedAnnotation: Annotation? {
        selected.flatMap { annotations.indices.contains($0) ? annotations[$0] : nil }
    }

    // MARK: Tools

    public mutating func select(tool newTool: Tool) {
        guard newTool != tool else { return }
        endTextEditing()
        tool = newTool
        // Only the select tool has a selection; switching to a drawing tool
        // drops it, so its handles stop competing with the new shape's drag.
        if newTool != .select { selected = nil }
        draft = nil
        cropDraft = nil
        drag = .none
    }

    /// Apply the current style to the selected annotation, if there is one.
    /// Go back to the select tool, with the annotation just finished left
    /// selected.
    ///
    /// Every tool is one-shot: you arm it, you draw one thing, and you are back
    /// on select. That is what makes the single-key shortcuts usable — after
    /// drawing you can immediately drag what you made, or recolour it, without
    /// first remembering to press `s`. It also removes the commonest accident
    /// in the Rust original, where the tool stayed armed and the next click
    /// meant to adjust a shape drew another one on top of it.
    ///
    /// Leaving it selected is the other half: the thing you just drew is
    /// obviously what you want to nudge or restyle next.
    private mutating func disarm(selecting index: Int?) {
        tool = .select
        draft = nil
        drag = .none
        if let index, annotations.indices.contains(index) {
            selected = index
            // Adopt the shape's style, so the toolbar keeps showing the colour
            // and weight of what is now selected.
            style = EditorStyle(color: annotations[index].color,
                                width: annotations[index].width,
                                fontSize: annotations[index].fontSize,
                                opacity: annotations[index].opacity)
        }
    }

    /// The toolbar calls this so a swatch restyles what is selected rather than
    /// only affecting the next shape drawn.
    public mutating func applyStyleToSelection() {
        guard let i = selected, annotations.indices.contains(i) else { return }
        checkpoint()
        annotations[i].color = style.color
        annotations[i].width = style.width
        annotations[i].fontSize = style.fontSize
        annotations[i].opacity = style.opacity
    }

    // MARK: Pointer

    /// - Returns: true if the editor consumed the event (so the view should not
    ///   treat it as a region-selection drag).
    @discardableResult
    public mutating func pointerDown(at point: CGPoint) -> Bool {
        endTextEditing()
        redoStack.removeAll()

        switch tool {
        case .select:
            return beginSelectDrag(at: point)

        case .crop:
            drag = .cropping(from: point)
            cropDraft = CGRect(origin: point, size: .zero)
            return true

        case .step:
            // A step is placed by a single click, not dragged out.
            checkpoint()
            annotations.append(Annotation(kind: .step(center: point, radius: AnnotationStyle.stepRadius),
                                          color: style.color, width: style.width,
                                          fontSize: style.fontSize, opacity: style.opacity))
            disarm(selecting: annotations.count - 1)
            return true

        case .text:
            checkpoint()
            annotations.append(Annotation(kind: .text(position: point, text: ""),
                                          color: style.color, width: style.width,
                                          fontSize: style.fontSize, opacity: style.opacity))
            selected = annotations.count - 1
            editingText = annotations.count - 1
            drag = .none
            return true

        case .arrow, .rectangle, .ellipse, .pencil, .highlight, .blur, .callout:
            draft = Annotation(kind: initialKind(for: tool, at: point),
                               color: style.color, width: style.width,
                               fontSize: style.fontSize, opacity: style.opacity)
            drag = .creating(from: point)
            return true
        }
    }

    private mutating func beginSelectDrag(at point: CGPoint) -> Bool {
        // A handle on the current selection wins over everything: handles sit
        // on top of the shape and often outside it.
        if let i = selected, annotations.indices.contains(i),
           let handle = annotations[i].hitTestHandle(point) {
            checkpoint()
            drag = .resizing(handle)
            return true
        }
        // Topmost first, so the shape drawn last is the one you grab.
        if let i = annotations.indices.reversed().first(where: { annotations[$0].hitTest(point) }) {
            selected = i
            style = EditorStyle(color: annotations[i].color, width: annotations[i].width,
                                fontSize: annotations[i].fontSize, opacity: annotations[i].opacity)
            checkpoint()
            drag = .moving(from: point)
            return true
        }
        selected = nil
        drag = .none
        return false
    }

    private func initialKind(for tool: Tool, at p: CGPoint) -> Annotation.Kind {
        switch tool {
        case .arrow: return .arrow(start: p, end: p)
        case .rectangle: return .rect(origin: p, size: .zero)
        case .ellipse: return .ellipse(origin: p, size: .zero)
        case .pencil: return .pencil(points: [p])
        case .highlight: return .highlight(origin: p, size: .zero)
        case .blur: return .blur(origin: p, size: .zero)
        case .callout: return .callout(origin: p, size: .zero, pointer: p, text: "")
        case .text: return .text(position: p, text: "")
        case .step: return .step(center: p, radius: AnnotationStyle.stepRadius)
        case .select, .crop: return .rect(origin: p, size: .zero)
        }
    }

    @discardableResult
    public mutating func pointerDragged(to point: CGPoint) -> Bool {
        switch drag {
        case .none:
            return false
        case .creating:
            draft?.update(with: point)
            return true
        case let .moving(from):
            guard let i = selected, annotations.indices.contains(i) else { return false }
            annotations[i].translate(dx: point.x - from.x, dy: point.y - from.y)
            drag = .moving(from: point)
            return true
        case let .resizing(handle):
            guard let i = selected, annotations.indices.contains(i) else { return false }
            annotations[i].applyResize(handle, to: point)
            return true
        case let .cropping(from):
            cropDraft = Annotation.normalizeRect(
                from, CGSize(width: point.x - from.x, height: point.y - from.y))
            return true
        }
    }

    /// - Returns: the committed crop rect, if this drag was a crop.
    @discardableResult
    public mutating func pointerUp(at point: CGPoint) -> CGRect? {
        defer { drag = .none }

        switch drag {
        case let .creating(from):
            guard var shape = draft else { return nil }
            draft = nil
            shape.update(with: point)
            // Discard shapes too small to be seen, hit or deleted. Without
            // this a stray click leaves an artifact with an empty bounding
            // rect, which nothing can ever select again.
            //
            // The drag distance is the reliable test, and it has to come first:
            // a callout's bubble is synthesized at a minimum size and a pencil
            // click still records its point two or three times, so both look
            // big enough to keep if you only measure the shape.
            guard from.distance(to: point) >= 3, isWorthKeeping(shape) else { return nil }
            checkpoint()
            annotations.append(shape)
            if case .callout = shape.kind {
                // Not finished yet: a callout without its text is half-made, so
                // the tool stays armed until `endTextEditing`.
                selected = annotations.count - 1
                editingText = annotations.count - 1
            } else {
                disarm(selecting: annotations.count - 1)
            }
            return nil

        case .cropping:
            let rect = cropDraft
            cropDraft = nil
            // Ignore a click or a sliver; cropping to nothing is never meant.
            guard let rect, rect.width >= 5, rect.height >= 5 else { return nil }
            // A crop applies once. Leaving it armed means the next drag
            // silently re-crops the region the user just settled on.
            disarm(selecting: nil)
            return rect

        case .moving, .resizing:
            // Normalise a shape dragged inside-out so its handles stay put.
            if let i = selected, annotations.indices.contains(i) {
                annotations[i].normalize()
            }
            return nil

        case .none:
            return nil
        }
    }

    /// Rejects slivers — a box dragged 200pt sideways but 0pt down. The drag
    /// distance alone would keep those, and they are unusable.
    private func isWorthKeeping(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case let .rect(_, size), let .ellipse(_, size), let .highlight(_, size), let .blur(_, size):
            return abs(size.width) >= 3 && abs(size.height) >= 3
        case let .pencil(points):
            // Two identical points are a click that jittered, not a stroke.
            return Set(points.map { "\($0.x),\($0.y)" }).count >= 2
        case .arrow, .callout, .text, .step:
            return true
        }
    }

    // MARK: Text

    /// Replace the text of the annotation being typed into.
    public mutating func setEditingText(_ text: String) {
        guard let i = editingText, annotations.indices.contains(i) else { return }
        switch annotations[i].kind {
        case let .text(position, _):
            annotations[i].kind = .text(position: position, text: text)
        case let .callout(origin, size, pointer, _):
            annotations[i].kind = .callout(origin: origin, size: size, pointer: pointer, text: text)
        default:
            break
        }
    }

    /// Finish typing. An empty text annotation is removed — an invisible shape
    /// the user cannot see is worse than nothing.
    public mutating func endTextEditing() {
        guard let i = editingText else { return }
        editingText = nil
        guard annotations.indices.contains(i) else { return }
        let isEmpty: Bool
        switch annotations[i].kind {
        case let .text(_, text): isEmpty = text.isEmpty
        case let .callout(_, _, _, text): isEmpty = text.isEmpty
        default: isEmpty = false
        }
        if isEmpty {
            annotations.remove(at: i)
            if selected == i { selected = nil }
            // The checkpoint taken when it was created would restore it, so
            // drop that too: creating and abandoning an empty label is not an
            // edit worth an undo step.
            if !undoStack.isEmpty { undoStack.removeLast() }
            // Nothing was made, so the tool stays armed: the user typed
            // nothing and almost certainly meant to try again.
            return
        }
        // The label is finished, so the tool that placed it is spent.
        disarm(selecting: i)
    }

    // MARK: Editing commands

    /// Add a finished annotation directly (seeding the canvas, or a caller
    /// that builds shapes itself rather than by dragging).
    public mutating func append(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    /// Append without recording an undo step.
    ///
    /// For loading an existing list into the editor — as the recording editor
    /// does every time the playhead moves. Checkpointing there would make undo
    /// walk back through frames the user never edited.
    public mutating func appendWithoutCheckpoint(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    /// Select by index, or clear if it is out of range.
    ///
    /// Needed to restore a selection after reloading the list, so the canvas and
    /// the document agree about what is selected.
    public mutating func selectAnnotation(at index: Int?) {
        guard let index, annotations.indices.contains(index) else {
            selected = nil
            return
        }
        selected = index
    }

    public mutating func clearSelection() {
        selected = nil
        endTextEditing()
    }

    public mutating func deleteSelected() {
        guard let i = selected, annotations.indices.contains(i) else { return }
        checkpoint()
        annotations.remove(at: i)
        selected = nil
        editingText = nil
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selected = nil
        editingText = nil
        draft = nil
        drag = .none
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selected = nil
        editingText = nil
        draft = nil
        drag = .none
    }

    /// Drop every annotation (the overlay reuses one editor across captures).
    public mutating func reset() {
        annotations = []
        undoStack = []
        redoStack = []
        selected = nil
        editingText = nil
        draft = nil
        cropDraft = nil
        drag = .none
        tool = .select
    }

    private mutating func checkpoint() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }
}
