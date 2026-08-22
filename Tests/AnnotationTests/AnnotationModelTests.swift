import CoreGraphics
import Foundation
import Testing
@testable import Annotation

// The Annotation target is pure model + geometry (AppKit-free by layering
// rule), so it gets real unit tests here — the overlay *view* is AppKit and
// rides the manual checklist instead.

// MARK: - Palette and style

@Test func theSwatchPaletteIsNineAndInRustOrder() {
    #expect(AnnotationColor.choices.count == 9)
    // First and last swatches, values transcribed from the Rust style panel.
    #expect(AnnotationColor.choices[0].r == 1.0)
    #expect(AnnotationColor.choices[0].g == 0.18)
    #expect(AnnotationColor.choices[0].b == 0.45)
    #expect(AnnotationColor.choices[8].r == 0.96)
    // Distinct swatches are distinct colors (no duplicates in the palette).
    #expect(Set(AnnotationColor.choices).count == 9)
}

@Test func swatchColorsBuildCgColors() {
    let color = AnnotationColor.choices[2]
    let cg = color.cgColor
    #expect(cg.alpha == 1)
}

@Test func strokeWidthPresetsMatchRust() {
    #expect(AnnotationStyle.strokeWidth(preset: 0) == 1.5)
    #expect(AnnotationStyle.strokeWidth(preset: 1) == 3.0)
    #expect(AnnotationStyle.strokeWidth(preset: 2) == 5.5)
    // Unknown presets fall back to medium.
    #expect(AnnotationStyle.strokeWidth(preset: 7) == 3.0)
}

@Test func theFontSizePolicy() {
    #expect(AnnotationStyle.fontSizes == 12...48)
    #expect(AnnotationStyle.defaultFontSize == 18)
    #expect(AnnotationStyle.defaultCalloutFontSize == 18)
}

// MARK: - Tools

@Test func theElevenToolsAreInToolbarOrder() {
    #expect(Tool.allCases.count == 11)
    #expect(Tool.allCases[0] == .select)
    #expect(Tool.allCases.last == .crop)
}

@Test func toolShortcutKeysAreDistinct() {
    let keys = Tool.allCases.map(\.shortcutKey)
    #expect(Set(keys).count == keys.count)
    #expect(Tool.text.shortcutKey == "t")
    #expect(Tool.callout.shortcutKey == "q")
}

// MARK: - Model

@Test func aDefaultAnnotationIsPinkMediumOpaque() {
    let a = Annotation(kind: .rect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 10, height: 10)))
    #expect(a.color == AnnotationColor.choices[0])
    #expect(a.width == AnnotationStyle.strokeMedium)
    #expect(a.opacity == 1)
}

@Test func annotationsWithDifferentColorsDiffer() {
    let red = Annotation(kind: .rect(origin: .zero, size: .init(width: 10, height: 10)),
                         color: AnnotationColor(r: 1, g: 0, b: 0))
    let blue = Annotation(kind: .rect(origin: .zero, size: .init(width: 10, height: 10)),
                          color: AnnotationColor(r: 0, g: 0, b: 1))
    #expect(red != blue)
}

@Test func sameAnnotationEncodesIdentically() {
    let a = Annotation(kind: .step(center: CGPoint(x: 40, y: 30), radius: 14),
                       color: AnnotationColor(r: 0.5, g: 0.2, b: 0.8))
    let b = a
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
}

@Test func theCodableRoundTrip() throws {
    let original = [
        Annotation(kind: .arrow(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 90, y: 40)),
                   color: .choices[3], width: 5.5),
        Annotation(kind: .rect(origin: CGPoint(x: 5, y: 5), size: CGSize(width: 50, height: 30)),
                   color: .choices[4]),
        Annotation(kind: .ellipse(origin: CGPoint(x: -10, y: 0), size: CGSize(width: 20, height: 20)),
                   color: .choices[5]),
        Annotation(kind: .pencil(points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 4, y: 2)]),
                   color: .choices[6]),
        Annotation(kind: .text(position: CGPoint(x: 8, y: 9), text: "hello world"),
                   color: .choices[7], fontSize: 24, opacity: 0.5),
        Annotation(kind: .callout(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 120, height: 60),
                                   pointer: CGPoint(x: 60, y: 200), text: "note"),
                   color: .choices[8], fontSize: 16),
        Annotation(kind: .highlight(origin: CGPoint(x: 3, y: 4), size: CGSize(width: 60, height: 20)),
                   color: .choices[2], opacity: 0.4),
        Annotation(kind: .step(center: CGPoint(x: 50, y: 50), radius: 14),
                   color: .choices[1]),
        Annotation(kind: .blur(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 40, height: 25)),
                   color: .choices[0], opacity: 0.8),
    ]
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode([Annotation].self, from: data)
    #expect(decoded == original)
}

// MARK: - Geometry

@Test func normalizeRectFlipsNegativeSizes() {
    let r = Annotation.normalizeRect(CGPoint(x: 100, y: 100), CGSize(width: -40, height: -20))
    #expect(r == CGRect(x: 60, y: 80, width: 40, height: 20))
    // Non-negative input passes through.
    let r2 = Annotation.normalizeRect(CGPoint(x: 1, y: 2), CGSize(width: 3, height: 4))
    #expect(r2 == CGRect(x: 1, y: 2, width: 3, height: 4))
}

@Test func rectHandlesAreEight() {
    let handles = Annotation.rectHandles(CGRect(x: 0, y: 0, width: 100, height: 50))
    #expect(handles.count == 8)
    // Every kind appears exactly once.
    let kinds = handles.map(\.0)
    #expect(Set(kinds).count == 8)
    #expect(kinds.contains(.topLeft))
    #expect(kinds.contains(.bottomRight))
}

@Test func applyRectResizePinsTheOppositeEdge() {
    let r = CGRect(x: 10, y: 10, width: 100, height: 50)
    // Drag the top-left out; the bottom-right must not move.
    let out = Annotation.applyRectResize(r, handle: .topLeft, to: CGPoint(x: 0, y: 5))
    #expect(out.origin == CGPoint(x: 0, y: 5))
    #expect(out.maxX == r.maxX)
    #expect(out.maxY == r.maxY)
    // Edge handles move one axis only.
    let right = Annotation.applyRectResize(r, handle: .right, to: CGPoint(x: 130, y: 400))
    #expect(right.size.width == 120)
    #expect(right.origin == r.origin)
}

@Test func applyRectResizeNormalizesInvertedResult() {
    let r = CGRect(x: 10, y: 10, width: 100, height: 50)
    // Drag bottom-left past the left edge → the rect stays sane (positive size).
    let out = Annotation.applyRectResize(r, handle: .bottomLeft, to: CGPoint(x: 200, y: 200))
    #expect(out.width > 0)
    #expect(out.height > 0)
}

@Test func distanceToSegment() {
    // The midpoint of the closest approach to a unit segment.
    let p = CGPoint(x: 5, y: 5)
    let d = p.distance(toSegment: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))
    #expect(abs(d - 5) < 0.001)
    // Outside the segment's range: distance to the nearer endpoint.
    let q = CGPoint(x: 15, y: 0)
    let d2 = q.distance(toSegment: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))
    #expect(abs(d2 - 5) < 0.001)
}

@Test func pointInRectIncludesTheBorder() {
    let r = CGRect(x: 0, y: 0, width: 10, height: 10)
    #expect(CGPoint(x: 0, y: 0).isIn(r))
    #expect(CGPoint(x: 10, y: 10).isIn(r))
    #expect(!CGPoint(x: 10.001, y: 5).isIn(r))
}

@Test func inflateGrowsAllSides() {
    let r = CGRect(x: 0, y: 0, width: 10, height: 10).inflate(2)
    #expect(r == CGRect(x: -2, y: -2, width: 14, height: 14))
}

@Test func uniteTakesTheBoundingRect() {
    let r = CGRect(x: 0, y: 0, width: 10, height: 10).unite(CGRect(x: 5, y: 8, width: 10, height: 10))
    #expect(r == CGRect(x: 0, y: 0, width: 15, height: 18))
}

// MARK: - Bounding and hit-testing

@Test func arrowHitTestsAgainstItsSegment() {
    let a = Annotation(kind: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)))
    #expect(a.hitTest(CGPoint(x: 50, y: 3)))       // near the line: hit
    #expect(!a.hitTest(CGPoint(x: 50, y: 30)))     // far away: miss
}

@Test func rectHitTestsItsPaddedBounds() {
    let a = Annotation(kind: .rect(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50)))
    #expect(a.hitTest(CGPoint(x: 50, y: 25)))      // inside
    #expect(!a.hitTest(CGPoint(x: 200, y: 25)))    // far outside
}

@Test func calloutHitTestsBubbleAndPointer() {
    let c = Annotation(kind: .callout(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 120, height: 60),
                                      pointer: CGPoint(x: 200, y: 200), text: "hi"))
    // The anchor point (on the bubble border) hits.
    let anchor = Annotation.calloutAnchorPoint(
        origin: CGPoint(x: 0, y: 0), size: CGSize(width: 120, height: 60),
        pointer: CGPoint(x: 200, y: 200))
    #expect(c.hitTest(anchor))
    // A point mid-segment hits.
    #expect(c.hitTest(CGPoint(x: 160, y: 160)))
    #expect(!c.hitTest(CGPoint(x: 500, y: 500)))  // nowhere near
}

@Test func theCalloutAnchorLiesOnTheBubbleBorder() {
    // Pointer to the right of the bubble → anchor on the right edge.
    let anchor = Annotation.calloutAnchorPoint(
        origin: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 40),
        pointer: CGPoint(x: 200, y: 20)
    )
    #expect(anchor.x == 100)   // right border
    #expect(anchor.y == 20)    // straight-out direction: mid-height
}

@Test func aStepHitTestsItsCircle() {
    let s = Annotation(kind: .step(center: CGPoint(x: 50, y: 50), radius: 20))
    #expect(s.hitTest(CGPoint(x: 50, y: 50)))
    #expect(!s.hitTest(CGPoint(x: 50, y: 100)))
}

// MARK: - Handles on annotations

@Test func aRectExposesEightHandles() {
    let a = Annotation(kind: .rect(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 100, height: 50)))
    #expect(a.resizeHandles().count == 8)
}

@Test func anArrowExposesItsEndpoints() {
    let a = Annotation(kind: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 80, y: 40)))
    let handles = a.resizeHandles()
    #expect(handles.count == 2)
    #expect(handles.contains { $0.0 == .arrowStart && $0.1 == CGPoint(x: 0, y: 0) })
    #expect(handles.contains { $0.0 == .arrowEnd && $0.1 == CGPoint(x: 80, y: 40) })
}

@Test func aCalloutAddsAPointerHandle() {
    let a = Annotation(kind: .callout(origin: .zero, size: CGSize(width: 100, height: 40),
                                      pointer: CGPoint(x: 60, y: 120), text: "x"))
    #expect(a.resizeHandles().count == 9)
    #expect(a.hitTestHandle(CGPoint(x: 60, y: 120)) == .calloutPointer)
}

@Test func handleHitTestNeedsTolerance() {
    let a = Annotation(kind: .rect(origin: .zero, size: CGSize(width: 100, height: 100)))
    // Exact corner: hit.
    #expect(a.hitTestHandle(CGPoint(x: 100, y: 0)) == .topRight)
    // Well away: no handle.
    #expect(a.hitTestHandle(CGPoint(x: 50, y: 50)) == nil)
}

// MARK: - Mutation

@Test func applyResizeMovesHandles() {
    var a = Annotation(kind: .rect(origin: .zero, size: CGSize(width: 100, height: 100)))
    a.applyResize(.topLeft, to: CGPoint(x: -10, y: -10))
    #expect(a.kind == .rect(origin: CGPoint(x: -10, y: -10), size: CGSize(width: 110, height: 110)))
}

@Test func applyResizeMovesAnArrowsEndpoint() {
    var a = Annotation(kind: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 50, y: 50)))
    a.applyResize(.arrowEnd, to: CGPoint(x: 70, y: 30))
    #expect(a.kind == .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 70, y: 30)))
}

@Test func translateMovesEveryKind() {
    var shapes: [Annotation] = [
        .init(kind: .arrow(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 3, y: 4))),
        .init(kind: .rect(origin: .zero, size: .init(width: 10, height: 10))),
        .init(kind: .ellipse(origin: .zero, size: .init(width: 10, height: 10))),
        .init(kind: .pencil(points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)])),
        .init(kind: .text(position: CGPoint(x: 5, y: 5), text: "t")),
        .init(kind: .callout(origin: .zero, size: .init(width: 10, height: 10),
                              pointer: CGPoint(x: 3, y: 3), text: "c")),
        .init(kind: .highlight(origin: .zero, size: .init(width: 10, height: 10))),
        .init(kind: .step(center: CGPoint(x: 5, y: 5), radius: 10)),
        .init(kind: .blur(origin: .zero, size: .init(width: 10, height: 10))),
    ]
    let before = shapes.map { $0.boundingRect() }
    for i in shapes.indices { shapes[i].translate(dx: 7, dy: -3) }
    for i in shapes.indices {
        let after = shapes[i].boundingRect()
        #expect(abs(after.minX - (before[i].minX + 7)) < 0.001)
        #expect(abs(after.minY - (before[i].minY - 3)) < 0.001)
    }
}

@Test func updateReroutesAnArrowsEnd() {
    var a = Annotation(kind: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10)))
    a.update(with: CGPoint(x: 40, y: 40))
    #expect(a.kind == .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 40)))
}

@Test func updateAppendsPencilPoints() {
    var a = Annotation(kind: .pencil(points: [CGPoint(x: 0, y: 0)]))
    a.update(with: CGPoint(x: 1, y: 1))
    a.update(with: CGPoint(x: 2, y: 0))
    guard case .pencil(let points) = a.kind else {
        Issue.record("kind changed")
        return
    }
    #expect(points.count == 3)
}

@Test func aDraggedRectCanBeNegativeAndNormalizes() {
    // Drawing right-to-left yields a negative-size rect; the bounding rect
    // normalizes it.
    let a = Annotation(kind: .rect(origin: CGPoint(x: 100, y: 100), size: CGSize(width: -40, height: -20)),
                       width: 0)
    let b = a.boundingRect()
    #expect(b == CGRect(x: 60, y: 80, width: 40, height: 20))
    // With the default (medium) stroke, the bounding rect is padded by the
    // stroke width on every side.
    let a2 = Annotation(kind: .rect(origin: CGPoint(x: 100, y: 100), size: CGSize(width: -40, height: -20)))
    let b2 = a2.boundingRect()
    #expect(b2 == CGRect(x: 60 - 3, y: 80 - 3, width: 40 + 6, height: 20 + 6))
}

// MARK: - Text measurement (CoreText, AppKit-free)

@Test func textMeasuresWithPositiveSize() {
    let size = ("hello world" as String).measure(size: 18)
    #expect(size.width > 0)
    #expect(size.height > 0)
}

@Test func longerTextMeasuresWider() {
    let short = ("hi" as String).measure(size: 18)
    let long = ("hello, world!" as String).measure(size: 18)
    #expect(long.width > short.width)
}

@Test func emptyTextMeasuresToZero() {
    let size = ("" as String).measure(size: 18)
    #expect(size == .zero)
}

@Test func aTextAnnotationBoundsItsMeasuredSize() {
    let a = Annotation(kind: .text(position: CGPoint(x: 10, y: 10), text: "hello world"))
    let b = a.boundingRect()
    #expect(b.origin == CGPoint(x: 10, y: 10))
    #expect(b.width > 0 && b.height > 0)
}
