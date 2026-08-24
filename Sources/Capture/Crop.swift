import CoreGraphics

/// A captured screenshot together with the scale factor used to present it.
///
/// The scale factor (points → pixels) is the link between the overlay's
/// logical (point) coordinate space and the `CGImage`'s pixel space. Cropping
/// the confirmed selection needs it, so it travels with the image rather than
/// being recomputed (and possibly disagreeing) at the crop site.
public struct CapturedImage: Equatable, Sendable {
    public let image: CGImage
    public let scale: CGFloat

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    /// The image's pixel dimensions.
    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

/// Crops a full-display capture to the user's confirmed selection.
///
/// `selection` is in the overlay's logical (point) space — top-left origin, the
/// same space the flipped `OverlayView` draws in. Because the capture is of the
/// *same* display the overlay covers, no display-origin is needed: the
/// `CGImage`'s pixel (0,0) is the top-left of the captured region, and
/// `selection` scaled by the backing scale factor maps straight onto it.
///
/// Pure and AppKit-free (CoreGraphics only): the point→pixel math is the part
/// with decisions in it, so it is a named function with unit tests rather than
/// a few multiplications buried in the session.
public enum CropImage {
    /// A normalized rect from an origin/size pair (which may be negative while
    /// a drag is in progress). Mirrors the annotation model's normalization.
    public static func normalized(_ origin: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(
            x: size.width < 0 ? origin.x + size.width : origin.x,
            y: size.height < 0 ? origin.y + size.height : origin.y,
            width: abs(size.width), height: abs(size.height)
        )
    }

    /// Crop `source` to `selection` (points, top-left origin) scaled by `scale`.
    ///
    /// - Returns: The cropped `CGImage`, or `nil` if the selection is empty or
    ///   lies entirely outside the source (a `CGImage` crop of an out-of-bounds
    ///   or zero rect returns `nil`).
    public static func crop(
        _ source: CGImage,
        selection: CGRect,
        scale: CGFloat
    ) -> CGImage? {
        let rect = normalized(
            CGPoint(x: selection.minX, y: selection.minY),
            CGSize(width: selection.width, height: selection.height)
        )
        let pixelX = Int((rect.minX * scale).rounded())
        let pixelY = Int((rect.minY * scale).rounded())
        let pixelW = Int((rect.width * scale).rounded())
        let pixelH = Int((rect.height * scale).rounded())
        guard pixelW > 0, pixelH > 0 else { return nil }
        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
        return source.cropping(to: cropRect)
    }
}
