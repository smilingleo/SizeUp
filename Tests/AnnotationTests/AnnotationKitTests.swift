import Testing
@testable import Annotation

// `Annotation` is AppKit-free (CoreGraphics/CoreText only — see the layering
// lint), so its logic is testable without a window on screen. The model lands
// in C1 Task 4 with its tests; this placeholder exists so the target compiles
// and the empty-directory warning is gone.
@Test func theElevenToolKindsAreListed() {
    #expect(AnnotationKit.allKinds.count == 11)
    #expect(Set(AnnotationKit.allKinds).count == 11)
    #expect(AnnotationKit.allKinds.first == "select")
    #expect(AnnotationKit.allKinds.last == "crop")
}
