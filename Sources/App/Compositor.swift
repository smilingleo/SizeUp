import Annotation
import Capture
import CoreGraphics

/// Flattens the region and its annotations into the image that gets copied or
/// saved.
///
/// Without this the whole editor is decorative: the crop would come out clean
/// and every shape the user drew would be silently discarded.
enum Compositor {
    /// - Parameters:
    ///   - image: the full-display screenshot, in pixels.
    ///   - selection: the region, in view points (top-left origin).
    ///   - scale: points → pixels for that display.
    ///   - annotations: shapes in the same point space as `selection`.
    static func flatten(
        _ image: CGImage,
        selection: CGRect,
        scale: CGFloat,
        annotations: [Annotation]
    ) -> CGImage? {
        guard let cropped = CropImage.crop(image, selection: selection, scale: scale) else {
            return nil
        }
        // Nothing drawn: hand back the plain crop rather than paying for a
        // round trip through a new bitmap.
        guard !annotations.isEmpty else { return cropped }

        let width = cropped.width, height = cropped.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Move into the annotations' coordinate space: top-left origin, points
        // rather than pixels, and with the region's own origin at zero. Doing it
        // as one transform is what keeps a shape landing exactly where the user
        // saw it, at any scale factor.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -selection.minX, y: -selection.minY)

        // The blur samples the untouched screenshot, so it mosaics the real
        // pixels rather than whatever has already been drawn over them.
        AnnotationRenderer.draw(annotations, in: context, blurSource: image, blurScale: scale)

        return context.makeImage() ?? cropped
    }
}
