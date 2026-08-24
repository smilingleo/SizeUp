import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Encodes a sequence of `CGImage` frames into an H.264 MP4.
///
/// `AVAssetWriter` with a pixel-buffer adaptor, which is the only way to feed
/// still images to the hardware encoder without going through a capture
/// session. Frames go in at a fixed rate: the recorder decides *which* frame
/// belongs at which index (see `Recording.frameCount(forElapsed:)`), and this
/// type just honours the index it is given.
///
/// Errors are values rather than traps — running out of disk half way through a
/// recording should stop the recording, not the app.
public final class VideoEncoder {
    public enum Failure: Error, CustomStringConvertible {
        case writerUnavailable
        case cannotAddInput
        case noPixelBufferPool
        case cannotCreatePixelBuffer
        case startFailed(String)
        case finishFailed(String)

        public var description: String {
            switch self {
            case .writerUnavailable: return "could not create the video writer"
            case .cannotAddInput: return "the writer rejected the video input"
            case .noPixelBufferPool: return "the writer produced no pixel buffer pool"
            case .cannotCreatePixelBuffer: return "could not allocate a frame buffer"
            case let .startFailed(reason): return "could not start writing: \(reason)"
            case let .finishFailed(reason): return "could not finish writing: \(reason)"
            }
        }
    }

    public let url: URL
    /// Frame size in pixels. Both are even: H.264 encodes in 2x2 chroma blocks,
    /// and an odd dimension is either rejected or silently rounded.
    public let width: Int
    public let height: Int

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    private var frameIndex = 0

    public init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height

        guard let writer = try? AVAssetWriter(url: url, fileType: .mp4) else {
            throw Failure.writerUnavailable
        }
        self.writer = writer

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // False, despite this being a screen recording. The flag means "drop
        // rather than block", which suits a live source pushing samples it can
        // afford to lose. Here the frame count *is* the timeline: dropping a
        // frame shortens the video and speeds it up, so waiting is correct.
        input.expectsMediaDataInRealTime = false

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])

        guard writer.canAdd(input) else { throw Failure.cannotAddInput }
        writer.add(input)
    }

    public func start() throws {
        guard !started else { return }
        guard writer.startWriting() else {
            throw Failure.startFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    /// The number of frames written so far, which is also the index the next
    /// frame will take.
    public var framesWritten: Int { frameIndex }

    /// Append `image` as the next frame.
    ///
    /// - Returns: false only if the writer has failed, which the recorder treats
    ///   as "stop trying" — a failed writer never recovers.
    @discardableResult
    public func append(_ image: CGImage) -> Bool {
        guard started, writer.status == .writing else { return false }
        // The recorder can append several frames in one tick when it is catching
        // up, and the writer goes "not ready" partway through a burst like that.
        // A refusal is back-pressure, not an error: returning false here would
        // lose the frame and, because the recorder stops on false, silently end
        // the recording. So wait for the writer instead.
        guard waitUntilReady() else { return false }
        guard let pool = adaptor.pixelBufferPool else { return false }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else {
            return false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        // 32BGRA with the host byte order, matching the pool's pixel format.
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return false }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(Recording.fps))
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else { return false }
        frameIndex += 1
        return true
    }

    /// Block briefly until the writer will take another frame.
    ///
    /// Bounded so a wedged writer cannot hang the recording loop forever; a
    /// timeout is reported as failure, which stops the recording and keeps
    /// whatever was written up to that point.
    private func waitUntilReady(timeout: TimeInterval = 1) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    /// Close the file. Blocking, because the caller is about to hand the URL to
    /// a save dialog and a half-written MP4 is not playable.
    public func finish() throws {
        guard started else { return }
        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting { group.leave() }
        group.wait()
        started = false
        if writer.status == .failed {
            throw Failure.finishFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// Abandon the recording and remove the partial file.
    public func cancel() {
        if started {
            input.markAsFinished()
            writer.cancelWriting()
            started = false
        }
        try? FileManager.default.removeItem(at: url)
    }
}
