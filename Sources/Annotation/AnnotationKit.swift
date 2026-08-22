import CoreGraphics

/// The annotation model and its CoreGraphics/CoreText renderer.
///
/// AppKit-free on purpose (layering lint): text is drawn with CoreText
/// (`CTFont`/`CTLine`) into a bitmap context — verified to render identically
/// without `NSFont` — so the target keeps the same no-AppKit rule as
/// `Geometry`. Everything here is value types plus pure drawing, testable
/// against synthetic bitmaps.

// The model lands in C1 Task 4 (`Annotation.Kind`, `AnnotationStyle`,
// `Annotation`); the renderer in C2. This file exists so the target and its
// lint row are in place before code lands in them.
public enum AnnotationKit {
    /// The eleven tools the capture canvas offers, in the order the Rust
    /// ClipShot toolbar lists them. Fixed now because the toolbar's button
    /// layout and the overlay's draw seam both key off this list.
    public static let allKinds: [String] = [
        "select", "arrow", "rectangle", "ellipse", "pencil", "text",
        "callout", "highlight", "step", "blur", "crop",
    ]
}
