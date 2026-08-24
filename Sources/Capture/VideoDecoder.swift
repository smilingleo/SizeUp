import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// Reads frames out of a recorded video by frame index.
///
/// Two access patterns, because they have opposite costs:
///
/// - **random** (`frame(at:)`) for scrubbing and for drawing the editor, backed
///   by `AVAssetImageGenerator` and a small LRU cache. Opening is cheap: the
///   editor can appear after decoding one frame.
/// - **sequential** (`SequentialReader`) for export, backed by `AVAssetReader`,
///   which decodes forward at a fraction of the cost per frame.
///
/// Frame indices are *source* indices — positions in the file. Mapping the
/// editor's timeline onto them is `RecordingEdit`'s job.
public final class VideoDecoder {
    public enum Failure: Error, CustomStringConvertible {
        case noVideoTrack
        case unreadable(String)

        public var description: String {
            switch self {
            case .noVideoTrack: return "the file has no video track"
            case let .unreadable(why): return "the video could not be read: \(why)"
            }
        }
    }

    public let url: URL
    public let fps: Double
    public let pixelSize: CGSize
    /// Frames in the file, estimated from duration and frame rate.
    public let totalFrames: Int

    private let asset: AVURLAsset
    private let generator: AVAssetImageGenerator
    private var cache = FrameCache(limit: 120)

    public init(url: URL) async throws {
        self.url = url
        let asset = AVURLAsset(url: url)
        self.asset = asset

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let rate = (try? await track.load(.nominalFrameRate)) ?? 0
        // A file that reports a nonsensical rate still has to open, or a
        // recording becomes unrecoverable; 30 matches what the recorder writes.
        fps = (rate.isFinite && rate > 0) ? Double(rate) : 30
        let size = (try? await track.load(.naturalSize)) ?? .zero
        pixelSize = CGSize(width: abs(size.width), height: abs(size.height))

        let duration = ((try? await asset.load(.duration)) ?? .zero).seconds
        totalFrames = (duration.isFinite && duration > 0)
            ? max(Int((duration * fps).rounded()), 1)
            : 0

        generator = AVAssetImageGenerator(asset: asset)
        // Frame-accurate. Without both tolerances the generator is free to
        // return the nearest keyframe, which on a 30fps H.264 file can be a
        // second away -- annotations would appear over the wrong moment and
        // scrubbing would stick.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
    }

    /// The frame at a source index, or nil if it cannot be decoded.
    public func frame(at index: Int) -> CGImage? {
        guard index >= 0 else { return nil }
        if let cached = cache.value(for: index) { return cached }
        let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }
        cache.insert(image, for: index)
        return image
    }

    /// Drop cached frames. Called when the editor's frame mapping changes, since
    /// the same index then means a different picture.
    public func invalidateCache() {
        cache = FrameCache(limit: 120)
    }

    /// A forward-only reader for export.
    ///
    /// Export touches every frame once in order, which is the case
    /// `AVAssetImageGenerator` is worst at — it re-seeks per frame. This decodes
    /// straight through instead.
    public final class SequentialReader {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        /// The last frame decoded, returned again when the caller asks for an
        /// index that repeats (a freeze) or when the file runs short.
        private var lastImage: CGImage?
        private var nextIndex = 0
        private let context = CIContext()

        init(asset: AVURLAsset, track: AVAssetTrack) throws {
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw Failure.unreadable("\(error)")
            }
            guard reader.canAdd(output) else {
                throw Failure.unreadable("the reader refused the video track")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw Failure.unreadable("\(reader.error.map(String.init(describing:)) ?? "unknown")")
            }
        }

        /// Decode forward until `index` is reached, and return that frame.
        ///
        /// Asking for an index at or before the last one returns the cached
        /// frame rather than seeking backwards, which is exactly what a freeze
        /// needs: the same picture several times in a row.
        public func frame(at index: Int) -> CGImage? {
            while nextIndex <= index {
                guard let buffer = output.copyNextSampleBuffer() else {
                    // The file ended earlier than the frame count suggested.
                    // Repeating the last frame keeps the export the length the
                    // timeline promised instead of truncating it.
                    return lastImage
                }
                if let image = Self.image(from: buffer, context: context) {
                    lastImage = image
                }
                nextIndex += 1
            }
            return lastImage
        }

        private static func image(from buffer: CMSampleBuffer,
                                  context: CIContext) -> CGImage? {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return nil }
            let ci = CIImage(cvPixelBuffer: pixels)
            return context.createCGImage(ci, from: ci.extent)
        }
    }

    /// Open a forward-only reader over the same file.
    ///
    /// A fresh asset each time, with the track loaded *from that asset*: a
    /// reader rejects a track belonging to a different asset instance, and the
    /// failure reads as "the reader refused the video track", which points
    /// nowhere near the cause.
    public func makeSequentialReader() async throws -> SequentialReader {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        return try SequentialReader(asset: asset, track: track)
    }
}

/// A least-recently-used frame cache.
///
/// Bounded because a decoded 4K frame is tens of megabytes and scrubbing a long
/// recording would otherwise walk the process into swap.
struct FrameCache {
    private let limit: Int
    private var entries: [Int: CGImage] = [:]
    /// Indices in use order, oldest first.
    private var order: [Int] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    mutating func value(for index: Int) -> CGImage? {
        guard let image = entries[index] else { return nil }
        touch(index)
        return image
    }

    mutating func insert(_ image: CGImage, for index: Int) {
        entries[index] = image
        touch(index)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    private mutating func touch(_ index: Int) {
        if let existing = order.firstIndex(of: index) { order.remove(at: existing) }
        order.append(index)
    }

    var count: Int { entries.count }
}
