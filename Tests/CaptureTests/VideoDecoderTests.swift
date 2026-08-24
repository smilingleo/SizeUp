import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Capture

// The decoder is tested against files this suite encodes itself, so the frame at
// each index is known. That is the only way to catch the failure that matters:
// returning the nearest keyframe instead of the frame asked for.

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("clipshot-decode-\(UUID().uuidString).mp4")
}

/// Frames are identified *spatially*, by the length of a white bar, not by a
/// colour value.
///
/// The first version of these tests encoded the index in the green channel and
/// allowed +/-3 for compression. That does not work: H.264 stores BT.709 YUV at
/// limited range, so a flat sRGB fill comes back shifted by as much as 27 --
/// more than the gap between frames, which made the test unable to tell frames
/// apart at all, never mind the decoder. A bar's *length* survives the same
/// round trip to within a pixel or two.

private let barFrameSize = 160
private let barStep = 8

/// Frame `index` as a white bar `(index + 1) * barStep` pixels wide on black.
private func barFrame(_ index: Int) -> CGImage {
    let context = CGContext(data: nil, width: barFrameSize, height: barFrameSize,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: barFrameSize, height: barFrameSize))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: (index + 1) * barStep, height: barFrameSize))
    return context.makeImage()!
}

/// Recover the frame index by measuring the bar, or nil if there is no bar.
private func barIndex(of image: CGImage) -> Int? {
    var row = [UInt8](repeating: 0, count: barFrameSize * 4)
    let context = CGContext(data: &row, width: barFrameSize, height: 1,
                            bitsPerComponent: 8, bytesPerRow: barFrameSize * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squash the frame to a single row: the bar is full height, so any row will
    // do and averaging is more robust than sampling one line.
    context.draw(image, in: CGRect(x: 0, y: 0, width: barFrameSize, height: 1))
    let bright = (0..<barFrameSize).filter { row[$0 * 4] > 128 }.count
    guard bright > 0 else { return nil }
    return Int((Double(bright) / Double(barStep)).rounded()) - 1
}

/// Write `count` bar frames and return the file.
private func makeNumberedVideo(count: Int) async throws -> URL {
    let url = tempURL()
    let encoder = try VideoEncoder(url: url, width: barFrameSize, height: barFrameSize)
    try encoder.start()
    for i in 0..<count { _ = encoder.append(barFrame(i)) }
    try await encoder.finish()
    return url
}

@Test func theDecoderReportsWhatIsInTheFile() async throws {
    let url = try await makeNumberedVideo(count: 20)
    defer { try? FileManager.default.removeItem(at: url) }

    let decoder = try await VideoDecoder(url: url)
    #expect(decoder.fps == 30)
    #expect(decoder.pixelSize == CGSize(width: 160, height: 160))
    #expect(abs(decoder.totalFrames - 20) <= 1, "got \(decoder.totalFrames) frames")
}

@Test func aFrameIndexReturnsThatFrameAndNotAKeyframeNearIt() async throws {
    // AVAssetImageGenerator defaults to unbounded time tolerance, which returns
    // the nearest keyframe -- up to a second away. That would put annotations
    // over the wrong moment, so the decoder pins both tolerances to zero. This
    // test fails if that is ever removed.
    let url = try await makeNumberedVideo(count: 20)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try await VideoDecoder(url: url)

    for index in [0, 7, 12, 15, 19] {
        guard let frame = decoder.frame(at: index) else {
            Issue.record("frame \(index) did not decode")
            continue
        }
        #expect(barIndex(of: frame) == index,
                "asked for frame \(index), got \(barIndex(of: frame).map(String.init) ?? "nothing")")
    }
}

@Test func decodingIsIdempotent() async throws {
    // Scrubbing back and forth hits the same index repeatedly; the cache must
    // not change the answer.
    let url = try await makeNumberedVideo(count: 20)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try await VideoDecoder(url: url)
    let first = decoder.frame(at: 12).flatMap(barIndex(of:))
    _ = decoder.frame(at: 5)
    let again = decoder.frame(at: 12).flatMap(barIndex(of:))
    #expect(first == 12)
    #expect(first == again)
}

@Test func aNegativeIndexIsRefused() async throws {
    let url = try await makeNumberedVideo(count: 10)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try await VideoDecoder(url: url)
    #expect(decoder.frame(at: -1) == nil)
}

@Test func aFileWithNoVideoTrackIsRejected() async throws {
    // Not a crash and not an empty editor: the recording is simply unopenable.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipshot-nonsense-\(UUID().uuidString).mp4")
    try Data("this is not a video".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: (any Error).self) {
        _ = try await VideoDecoder(url: url)
    }
}

// MARK: Sequential reading

@Test func theSequentialReaderWalksForwardInOrder() async throws {
    let url = try await makeNumberedVideo(count: 20)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try await VideoDecoder(url: url)
    let reader = try await decoder.makeSequentialReader()

    for index in 0..<20 {
        guard let frame = reader.frame(at: index) else {
            Issue.record("sequential frame \(index) did not decode")
            continue
        }
        #expect(barIndex(of: frame) == index,
                "sequential frame \(index) came back as \(barIndex(of: frame).map(String.init) ?? "nothing")")
    }
}

@Test func askingTheSequentialReaderForARepeatedIndexRepeatsTheFrame() async throws {
    // This is what a freeze does: several output frames map to one source frame.
    // Seeking backwards would be wrong and slow; the reader holds the last frame.
    let url = try await makeNumberedVideo(count: 20)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try await VideoDecoder(url: url)
    let reader = try await decoder.makeSequentialReader()

    let first = reader.frame(at: 5).flatMap(barIndex(of:))
    let repeated = reader.frame(at: 5).flatMap(barIndex(of:))
    let againEarlier = reader.frame(at: 3).flatMap(barIndex(of:))
    #expect(first == repeated)
    #expect(first == againEarlier, "an earlier index returns the held frame, not nil")
}

@Test func theSequentialReaderRunsOutGracefully() async throws {
    // The frame count is estimated from duration, so it can overshoot by one.
    // Past the end the reader repeats rather than returning nil, so an export
    // does not end with a black frame or a gap.
    let url = try await makeNumberedVideo(count: 15)
    defer { try? FileManager.default.removeItem(at: url) }
    let decoder = try await VideoDecoder(url: url)
    let reader = try await decoder.makeSequentialReader()
    _ = reader.frame(at: 14)
    #expect(reader.frame(at: 200) != nil, "past the end must still yield a picture")
}

// MARK: The frame cache

@Test func theCacheEvictsTheLeastRecentlyUsed() {
    var cache = FrameCache(limit: 3)
    for i in 0..<3 { cache.insert(barFrame(i), for: i) }
    // Touch 0 so it is no longer the oldest.
    _ = cache.value(for: 0)
    cache.insert(barFrame(3), for: 3)

    #expect(cache.count == 3, "the cache must stay bounded")
    #expect(cache.value(for: 0) != nil, "a recently used frame survives")
    #expect(cache.value(for: 1) == nil, "the least recently used was dropped")
    #expect(cache.value(for: 3) != nil)
}

@Test func reinsertingDoesNotGrowTheCache() {
    var cache = FrameCache(limit: 4)
    for _ in 0..<10 { cache.insert(barFrame(1), for: 1) }
    #expect(cache.count == 1)
}

@Test func aZeroLimitCacheStillHoldsOneFrame() {
    // A limit of zero would otherwise evict what was just inserted and make
    // every lookup a miss.
    var cache = FrameCache(limit: 0)
    cache.insert(barFrame(1), for: 1)
    #expect(cache.value(for: 1) != nil)
}
