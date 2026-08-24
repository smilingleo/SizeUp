import Annotation
import Capture
import CoreGraphics
import Foundation

/// Burns an edit into a new video file.
///
/// This is the recording equivalent of `Compositor` in the screenshot path, and
/// it has the same rule: what is exported must match what the editor showed. So
/// it walks the *timeline*, asks the edit which source frame each output frame
/// maps to, and draws the annotations alive at that timeline frame — freezes and
/// speed changes fall out of that mapping rather than needing their own code.
public enum VideoExporter {
    public enum Failure: Error, CustomStringConvertible {
        case noFrames
        case cancelled

        public var description: String {
            switch self {
            case .noFrames: return "there is nothing to export"
            case .cancelled: return "the export was cancelled"
            }
        }
    }

    /// Progress, 0...1, reported on the caller's task.
    public typealias ProgressHandler = @Sendable (Double) -> Bool

    /// Export `edit` to `destination`.
    ///
    /// `annotationScale` converts annotation coordinates into video pixels. The
    /// editor stores annotations in the coordinates of the view the user drew
    /// them in, which is almost never the video's pixel size.
    ///
    /// - Parameter onProgress: return false to cancel.
    /// - Returns: the file written.
    @discardableResult
    public static func export(
        _ edit: RecordingEdit,
        to destination: URL,
        annotationScale: CGSize,
        onProgress: ProgressHandler? = nil
    ) async throws -> URL {
        let decoder = try await VideoDecoder(url: edit.videoURL)
        let width = Screenshot.even(Int(decoder.pixelSize.width))
        let height = Screenshot.even(Int(decoder.pixelSize.height))
        guard width > 0, height > 0, edit.totalFrames > 0 else {
            throw Failure.noFrames
        }

        let reader = try await decoder.makeSequentialReader()
        let encoder = try VideoEncoder(url: destination, width: width, height: height)
        try encoder.start()

        var lastSource = -1
        var lastFrame: CGImage?

        for output in 0..<edit.totalFrames {
            if let onProgress, !onProgress(Double(output) / Double(edit.totalFrames)) {
                encoder.cancel()
                throw Failure.cancelled
            }

            let source = edit.sourceFrame(forTimeline: output)
            // A freeze maps many output frames onto one source frame; decoding it
            // again would be wasted work and, with a forward-only reader, would
            // advance past it.
            if source != lastSource {
                lastFrame = reader.frame(at: source) ?? lastFrame
                lastSource = source
            }
            guard let picture = lastFrame else { continue }

            let visible = edit.annotations.filter { $0.range.contains(output) }
            // A frame with nothing on it goes through untouched. Redrawing it
            // through a bitmap context would re-encode it for no reason.
            if visible.isEmpty {
                _ = encoder.append(picture)
                continue
            }
            let composited = compose(picture, annotations: visible, outputFrame: output,
                                     fps: edit.fps, width: width, height: height,
                                     annotationScale: annotationScale)
            _ = encoder.append(composited ?? picture)
        }

        try await encoder.finish()
        _ = onProgress?(1)
        return destination
    }

    /// Draw `annotations` over `frame` at video resolution.
    static func compose(
        _ frame: CGImage,
        annotations: [TimedAnnotation],
        outputFrame: Int,
        fps: Double,
        width: Int,
        height: Int,
        annotationScale: CGSize
    ) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Annotations are authored in a top-left origin space, like the overlay.
        // Flip once, then scale, so every shape and every text baseline gets the
        // same treatment -- the same single-transform rule `Compositor` follows.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let sx = annotationScale.width > 0 ? CGFloat(width) / annotationScale.width : 1
        let sy = annotationScale.height > 0 ? CGFloat(height) / annotationScale.height : 1
        ctx.scaleBy(x: sx, y: sy)

        var step = 0
        for timed in annotations {
            if case .step = timed.annotation.kind { step += 1 }
            PulseEffect.draw(timed, stepNumber: step, frame: outputFrame, fps: fps,
                             in: ctx, blurSource: frame, blurScale: sx)
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
