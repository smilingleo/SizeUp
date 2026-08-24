import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Capture

// The encoder is the one part of recording that cannot be faked: either it
// produces a file AVFoundation will play back, or the whole feature is useless.
// These tests write real MP4s to a temporary directory and read them back.

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("clipshot-test-\(UUID().uuidString).mp4")
}

/// A frame with a distinguishable colour, so a decoded video can be checked.
private func frame(_ width: Int, _ height: Int, red: Double) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func theEncoderWritesAPlayableVideo() async throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let encoder = try VideoEncoder(url: url, width: 160, height: 120)
    try encoder.start()
    for i in 0..<30 {
        #expect(encoder.append(frame(160, 120, red: Double(i) / 30)))
    }
    try encoder.finish()

    #expect(FileManager.default.fileExists(atPath: url.path))

    // Read it back the way a video player would.
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1, "no video track — the file is not a usable video")

    let size = try await tracks[0].load(.naturalSize)
    #expect(Int(size.width) == 160)
    #expect(Int(size.height) == 120)

    // 30 frames at 30fps is one second.
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 1.0) < 0.1, "duration was \(duration.seconds)s")
}

@Test func frameCountDrivesTheDuration() async throws {
    // Pacing only works if the presentation times really are frameIndex/fps:
    // a fixed timestamp would collapse the video to a single frame.
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let encoder = try VideoEncoder(url: url, width: 64, height: 64)
    try encoder.start()
    for _ in 0..<Recording.fps * 2 { _ = encoder.append(frame(64, 64, red: 0.5)) }
    try encoder.finish()

    let duration = try await AVURLAsset(url: url).load(.duration)
    #expect(abs(duration.seconds - 2.0) < 0.15, "duration was \(duration.seconds)s")
}

@Test func theEncoderCountsWhatItWrote() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let encoder = try VideoEncoder(url: url, width: 64, height: 64)
    try encoder.start()
    #expect(encoder.framesWritten == 0)
    _ = encoder.append(frame(64, 64, red: 0))
    _ = encoder.append(frame(64, 64, red: 0))
    #expect(encoder.framesWritten == 2)
    encoder.cancel()
}

@Test func appendingBeforeStartingIsRefusedRatherThanCrashing() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let encoder = try VideoEncoder(url: url, width: 64, height: 64)
    #expect(!encoder.append(frame(64, 64, red: 0)))
    #expect(encoder.framesWritten == 0)
}

@Test func cancellingLeavesNoPartialFile() throws {
    // A half-written MP4 left in the save location would look like a finished
    // recording and would not play.
    let url = tempURL()
    let encoder = try VideoEncoder(url: url, width: 64, height: 64)
    try encoder.start()
    _ = encoder.append(frame(64, 64, red: 0))
    encoder.cancel()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func aFrameOfADifferentSizeIsScaledRatherThanRejected() async throws {
    // The capture can come back at a slightly different size than asked for
    // (rounding, or a display mode change mid-recording). Dropping those frames
    // would stall the recording; scaling them keeps it going.
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let encoder = try VideoEncoder(url: url, width: 100, height: 100)
    try encoder.start()
    #expect(encoder.append(frame(80, 60, red: 0.9)))
    try encoder.finish()

    let size = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        .load(.naturalSize)
    #expect(Int(size.width) == 100, "the output size must follow the encoder, not the frame")
}

@Test func anOddSizeIsRoundedDownBeforeItReachesTheEncoder() {
    // H.264 needs even dimensions. `even` is where that is enforced.
    #expect(Screenshot.even(101) == 100)
    #expect(Screenshot.even(1) == 0)
}
