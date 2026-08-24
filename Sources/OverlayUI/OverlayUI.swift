import AppKit
import Capture
import Annotation

/// The full-screen region-selection overlay, and (from C2) the annotation
/// canvas: a borderless, keyable window at the overlay level over the display
/// under the cursor, showing the captured screenshot.
///
/// AppKit by necessity — it is a window. The layering lint forbids it from
/// importing anything but its two dependencies, so all capture and annotation
/// logic it hosts comes from those targets.

// The window and view land in C1 Task 4. This file exists so the target and
// its lint row are in place before code lands in them.
public enum OverlayUI {
    /// The overlay window level, as a `CGWindowLevel`. 102: above the menu bar
    /// (24), status items (25), and normal windows (0), and the same level the
    /// Rust ClipShot overlay used.
    ///
    /// Defined in terms of `OverlayLevel.overlay` so the two cannot drift. The
    /// window itself once recomputed this inline and got 15 — see the note on
    /// `OverlayLevel` for why that spelling is a trap.
    public static let windowLevel = CGWindowLevel(OverlayLevel.overlay.rawValue)
}
