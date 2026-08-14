import CoreGraphics

/// Converts a Cocoa rect (bottom-left origin, +Y up) to an Accessibility
/// rect (top-left origin on the primary display, +Y down).
///
/// `primaryFrame` is `NSScreen.screens[0].frame` — the display carrying the
/// menu bar, whose top-left corner is the Accessibility origin.
public func axRect(fromCocoa rect: CGRect, primaryFrame: CGRect) -> CGRect {
    CGRect(
        x: rect.origin.x,
        y: primaryFrame.maxY - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

/// Inverse of `axRect(fromCocoa:primaryFrame:)`.
public func cocoaRect(fromAX rect: CGRect, primaryFrame: CGRect) -> CGRect {
    CGRect(
        x: rect.origin.x,
        y: primaryFrame.maxY - (rect.origin.y + rect.height),
        width: rect.width,
        height: rect.height
    )
}
