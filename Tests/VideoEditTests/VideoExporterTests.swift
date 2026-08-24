import Annotation
import AVFoundation
import Capture
import CoreGraphics
import Foundation
import Testing
@testable import VideoEdit

// Export is verified by decoding the result. Anything weaker cannot tell the
// difference between "the annotation was burned in" and "a file was written".

private let size = 160

private func tempURL(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("clipshot-export-\(tag)-\(UUID().uuidString).mp4")
}

/// A plain black source video, so anything non-black in the output came from an
/// annotation.
private func makeBlackVideo(frames: Int) async throws -> URL {
    let url = tempURL("src")
    let encoder = try VideoEncoder(url: url, width: size, height: size)
    try encoder.start()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let black = context.makeImage()!
    for _ in 0..<frames { _ = encoder.append(black) }
    try await encoder.finish()
    return url
}

/// How many pixels of a frame are not near-black — "is there ink on this frame".
private func inkCount(_ image: CGImage) -> Int {
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    let context = CGContext(data: &pixels, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    var count = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        // 60, not 0: H.264 lifts pure black slightly and rings around edges.
        if Int(pixels[i]) > 60 || Int(pixels[i + 1]) > 60 || Int(pixels[i + 2]) > 60 {
            count += 1
        }
    }
    return count
}

private func edit(_ url: URL, frames: Int, fps: Double = 30) -> RecordingEdit {
    RecordingEdit(videoURL: url, totalFrames: frames, fps: fps)
}

/// A fat white-ish rectangle, big enough to survive compression.
private func bigShape() -> Annotation {
    Annotation(kind: .rect(origin: CGPoint(x: 30, y: 30),
                           size: CGSize(width: 100, height: 100)),
               color: AnnotationColor(r: 1, g: 1, b: 1),
               width: 8)
}

@Test func exportWritesAPlayableVideoOfTheRightLength() async throws {
    let source = try await makeBlackVideo(frames: 60)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    var e = edit(source, frames: 60)
    e.add(bigShape(), at: 10)

    try await VideoExporter.export(e, to: out,
                                   annotationScale: CGSize(width: size, height: size))

    let asset = AVURLAsset(url: out)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 2) < 0.15, "duration was \(duration.seconds)s")
}

@Test func anAnnotationIsBurnedInOnItsFramesOnly() async throws {
    // The whole point of the editor: the shape has to be in the video, and only
    // while it was meant to be.
    let source = try await makeBlackVideo(frames: 90)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    var e = edit(source, frames: 90)
    e.add(bigShape(), at: 30)          // 30..<60
    e.setRange(0, start: 30, end: 60)

    try await VideoExporter.export(e, to: out,
                                   annotationScale: CGSize(width: size, height: size))

    let decoder = try await VideoDecoder(url: out)
    let before = decoder.frame(at: 10).map(inkCount) ?? 0
    let during = decoder.frame(at: 45).map(inkCount) ?? 0
    let after = decoder.frame(at: 80).map(inkCount) ?? 0

    #expect(during > 200, "the annotation is missing from the frames it covers (ink \(during))")
    #expect(before < during / 4, "ink before the annotation started (ink \(before))")
    #expect(after < during / 4, "the annotation outstayed its range (ink \(after))")
}

@Test func anOpenEndedAnnotationReachesTheLastFrame() async throws {
    let source = try await makeBlackVideo(frames: 45)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    var e = edit(source, frames: 45)
    e.add(bigShape(), at: 0)
    e.setRange(0, start: 0, end: nil)

    try await VideoExporter.export(e, to: out,
                                   annotationScale: CGSize(width: size, height: size))
    let decoder = try await VideoDecoder(url: out)
    #expect((decoder.frame(at: 44).map(inkCount) ?? 0) > 200)
}

@Test func aFreezeLengthensTheExportedVideo() async throws {
    // The exported file has to be as long as the timeline said, or the editor
    // was lying about what it would produce.
    let source = try await makeBlackVideo(frames: 60)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    var e = edit(source, frames: 60)
    e.insertFreeze(at: 30, holdFrames: 30)
    #expect(e.totalFrames == 90)

    try await VideoExporter.export(e, to: out,
                                   annotationScale: CGSize(width: size, height: size))
    let duration = try await AVURLAsset(url: out).load(.duration)
    #expect(abs(duration.seconds - 3) < 0.2, "duration was \(duration.seconds)s")
}

@Test func speedShortensTheExportedVideo() async throws {
    let source = try await makeBlackVideo(frames: 60)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    var e = edit(source, frames: 60)
    e.setPlaybackSpeed(2)

    try await VideoExporter.export(e, to: out,
                                   annotationScale: CGSize(width: size, height: size))
    let duration = try await AVURLAsset(url: out).load(.duration)
    #expect(abs(duration.seconds - 1) < 0.15, "duration was \(duration.seconds)s")
}

@Test func exportScalesAnnotationsIntoVideoPixels() async throws {
    // The editor draws in view points; the video is in pixels. If the scale is
    // ignored, a shape drawn in the middle of an 80-point view lands in the
    // top-left quarter of a 160-pixel video.
    let source = try await makeBlackVideo(frames: 30)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    var e = edit(source, frames: 30)
    // Fills the whole 80x80 view, so scaled up it must fill the whole video.
    e.add(Annotation(kind: .rect(origin: CGPoint(x: 5, y: 5),
                                 size: CGSize(width: 70, height: 70)),
                     color: AnnotationColor(r: 1, g: 1, b: 1), width: 6),
          at: 0)
    e.setRange(0, start: 0, end: nil)

    try await VideoExporter.export(e, to: out,
                                   annotationScale: CGSize(width: 80, height: 80))

    let decoder = try await VideoDecoder(url: out)
    let frame = try #require(decoder.frame(at: 10))

    // Sample near the far corner of the video. At 2x the rectangle's edge passes
    // close to it; unscaled it would be far away in empty black.
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    let context = CGContext(data: &pixels, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(frame, in: CGRect(x: 0, y: 0, width: size, height: size))
    func isInk(x: Int, y: Int) -> Bool {
        let i = (y * size + x) * 4
        return Int(pixels[i]) > 60 || Int(pixels[i + 1]) > 60 || Int(pixels[i + 2]) > 60
    }
    // The scaled rectangle spans 10...150 in both axes. Its right edge should be
    // somewhere past the middle of the frame.
    let inkPastMiddle = (size / 2..<size).contains { isInk(x: $0, y: size / 2) }
    #expect(inkPastMiddle, "the annotation was not scaled into video pixels")
}

@Test func progressIsReportedAndCancellationIsHonoured() async throws {
    let source = try await makeBlackVideo(frames: 60)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    let e = edit(source, frames: 60)

    // Cancel a fifth of the way in.
    await #expect(throws: VideoExporter.Failure.self) {
        try await VideoExporter.export(
            e, to: out, annotationScale: CGSize(width: size, height: size),
            onProgress: { $0 < 0.2 })
    }
    #expect(!FileManager.default.fileExists(atPath: out.path),
            "a cancelled export must not leave a partial file that looks finished")
}

@Test func progressRunsFromZeroToOne() async throws {
    let source = try await makeBlackVideo(frames: 30)
    let out = tempURL("out")
    defer {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: out)
    }
    let e = edit(source, frames: 30)
    let seen = Reported()
    try await VideoExporter.export(
        e, to: out, annotationScale: CGSize(width: size, height: size),
        onProgress: { seen.record($0); return true })

    #expect(seen.values.first == 0)
    #expect(seen.values.last == 1, "the last report must be 1, or a bar never fills")
    #expect(seen.values == seen.values.sorted(), "progress must not go backwards")
}

/// Collects progress values from the export's callback.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record(_ value: Double) {
        lock.lock(); storage.append(value); lock.unlock()
    }
    var values: [Double] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

// MARK: Pulse

@Test func pulseStrengthStaysInItsBand() {
    // Never zero: at zero the glow disappears and the annotation flickers
    // between highlighted and plain, which reads as a bug.
    for frame in 0..<200 {
        let s = PulseEffect.strength(frame: frame, fps: 30)
        #expect(s >= 0.35 && s <= 1.0001, "frame \(frame) gave \(s)")
    }
}

@Test func pulseBreathesRatherThanJumping() {
    // A cosine, so it eases at both ends. Sampling across one cycle must show
    // both a high and a low, and no discontinuity.
    let values = (0..<36).map { PulseEffect.strength(frame: $0, fps: 30) }
    #expect(values.max()! > 0.95)
    #expect(values.min()! < 0.45)
    let jumps = zip(values, values.dropFirst()).map { abs($1 - $0) }
    #expect(jumps.max()! < 0.35, "the pulse snaps instead of breathing")
}

@Test func pulseRepeatsEveryCycle() {
    // 1.2s at 30fps is 36 frames.
    #expect(abs(PulseEffect.strength(frame: 0, fps: 30)
                - PulseEffect.strength(frame: 36, fps: 30)) < 0.0001)
}

@Test func aPulsingAnnotationDrawsMoreInkThanAStillOne() {
    // The glow is the visible difference; this catches the pulse being silently
    // skipped in the draw path.
    func ink(pulses: Bool, at frame: Int) -> Int {
        let context = CGContext(data: nil, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let timed = TimedAnnotation(annotation: bigShape(),
                                    range: FrameRange(start: 0, end: nil),
                                    pulses: pulses)
        PulseEffect.draw(timed, frame: frame, fps: 30, in: context)
        return inkCount(context.makeImage()!)
    }
    // Frame 0 is the peak of the cycle, so the glow is at its strongest.
    #expect(ink(pulses: true, at: 0) > ink(pulses: false, at: 0))
}

@Test func onlyVisibleAnnotationsAreDrawn() {
    let context = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let timed = TimedAnnotation(annotation: bigShape(),
                                range: FrameRange(start: 100, end: 200))
    PulseEffect.drawAll([timed], frame: 5, fps: 30, in: context)
    #expect(inkCount(context.makeImage()!) == 0, "an annotation drew outside its range")
}

@Test func stepNumbersFollowTheStepsVisibleAtThatFrame() {
    // Numbering is a render-order property, and in a video "render order" means
    // the steps alive on this frame -- a step that has not appeared yet must not
    // consume a number.
    let first = TimedAnnotation(
        annotation: Annotation(kind: .step(center: CGPoint(x: 40, y: 40), radius: 14)),
        range: FrameRange(start: 0, end: 50))
    let second = TimedAnnotation(
        annotation: Annotation(kind: .step(center: CGPoint(x: 100, y: 40), radius: 14)),
        range: FrameRange(start: 100, end: 150))

    // At frame 120 only the second is alive, so it must be numbered 1.
    let context = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    PulseEffect.drawAll([first, second], frame: 120, fps: 30, in: context)
    let alone = inkCount(context.makeImage()!)

    // The same badge drawn as the only step in the list.
    let reference = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    PulseEffect.drawAll([second], frame: 120, fps: 30, in: reference)
    #expect(alone == inkCount(reference.makeImage()!),
            "the invisible earlier step still consumed a number")
}
