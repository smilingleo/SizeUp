import CoreGraphics
import Testing
@testable import Capture

// The recording model is pure, so the rules that decide what a video contains
// are testable without a screen, an encoder or a clock.

// MARK: Frame pacing

@Test func oneFrameIntervalIsOneFrame() {
    #expect(Recording.frameCount(forElapsed: 1.0 / 30.0) == 1)
}

@Test func aSecondIsThirtyFrames() {
    #expect(Recording.frameCount(forElapsed: 1) == Recording.fps)
}

@Test func pacingFollowsTheWallClock() {
    #expect(Recording.frameCount(forElapsed: 1.5) == 45)
    #expect(Recording.frameCount(forElapsed: 10) == 300)
}

@Test func aRecordingIsNeverZeroFrames() {
    // The recorder writes frames "until it has this many", so zero would
    // produce an empty file the encoder cannot close.
    #expect(Recording.frameCount(forElapsed: 0) == 1)
    #expect(Recording.frameCount(forElapsed: 0.0001) == 1)
}

@Test func pacingIsMonotonic() {
    // The frame count is used as a target to catch up to, so it must never go
    // backwards as time passes.
    var last = 0
    for step in 0...200 {
        let count = Recording.frameCount(forElapsed: Double(step) * 0.05)
        #expect(count >= last)
        last = count
    }
}

// MARK: Click detection

@Test func aPressFiresOnceNotOncePerFrame() {
    // Polling sees a held button as down on every frame. Thirty ripples for one
    // click is the bug this guards.
    var detector = ClickDetector()
    let first = detector.sample(leftDown: true, rightDown: false)
    #expect(first)
    for _ in 0..<30 {
        let held = detector.sample(leftDown: true, rightDown: false)
        #expect(!held, "a held button fired a second ripple")
    }
}

@Test func releasingThenPressingFiresAgain() {
    var detector = ClickDetector()
    let first = detector.sample(leftDown: true, rightDown: false)
    let released = detector.sample(leftDown: false, rightDown: false)
    let second = detector.sample(leftDown: true, rightDown: false)
    #expect(first)
    #expect(!released)
    #expect(second)
}

@Test func theRightButtonAlsoFires() {
    var detector = ClickDetector()
    let first = detector.sample(leftDown: false, rightDown: true)
    let held = detector.sample(leftDown: false, rightDown: true)
    #expect(first)
    #expect(!held)
}

@Test func bothButtonsTrackIndependently() {
    var detector = ClickDetector()
    let left = detector.sample(leftDown: true, rightDown: false)
    // Right goes down while left is still held: still a new click.
    let right = detector.sample(leftDown: true, rightDown: true)
    #expect(left)
    #expect(right)
}

@Test func noButtonsNeverFires() {
    var detector = ClickDetector()
    for _ in 0..<10 {
        let fired = detector.sample(leftDown: false, rightDown: false)
        #expect(!fired)
    }
}

// MARK: Ripple lifetime

@Test func aRippleIsAliveForItsDurationAndNoLonger() {
    let ripple = ClickRipple(position: .zero, frame: 100)
    let duration = Recording.clickRippleFrames
    #expect(ripple.progress(at: 100) == 0)
    #expect(ripple.progress(at: 100 + duration) == 1)
    #expect(ripple.progress(at: 100 + duration + 1) == nil)
    #expect(ripple.progress(at: 99) == nil, "a ripple cannot predate its click")
}

@Test func aRippleLastsAtLeastOneFrame() {
    // Guards against a frame rate or duration that rounds the life to zero,
    // which would make every ripple invisible.
    #expect(Recording.clickRippleFrames >= 1)
}

@Test func aRippleGrowsAndItsCenterGrowsMoreSlowly() {
    let ripple = ClickRipple(position: CGPoint(x: 50, y: 50), frame: 0)
    let start = ripple.ringRect(at: 0)
    let end = ripple.ringRect(at: 1)
    #expect(start.width == 20)
    #expect(end.width == 144)
    #expect(ripple.centerRect(at: 0).width == 10)
    #expect(ripple.centerRect(at: 1).width == 20)
    // Both stay centred on the click, which is the point of the whole effect.
    #expect(start.midX == 50 && start.midY == 50)
    #expect(end.midX == 50 && end.midY == 50)
}

// MARK: Pruning

@Test func finishedRipplesArePruned() {
    // A long recording must not accumulate every click ever made and pay to
    // draw all of them on every frame.
    var track = ClickRippleTrack()
    track.add(ClickRipple(position: .zero, frame: 0))
    track.add(ClickRipple(position: .zero, frame: 100))
    track.prune(before: 100)
    #expect(track.ripples.count == 1)
    #expect(track.ripples.first?.frame == 100)
}

@Test func aLiveRippleIsNotPruned() {
    var track = ClickRippleTrack()
    track.add(ClickRipple(position: .zero, frame: 50))
    track.prune(before: 50 + Recording.clickRippleFrames)
    #expect(track.ripples.count == 1, "a ripple was dropped on its last frame")
}

// MARK: Rendering

/// Count pixels that are not the background.
private func inkCount(_ size: Int, _ body: (CGContext) -> Void) -> Int {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    body(context)
    let image = context.makeImage()!
    var data = [UInt8](repeating: 0, count: size * size * 4)
    data.withUnsafeMutableBytes { raw in
        let c = CGContext(data: raw.baseAddress, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: size * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    var count = 0
    for i in stride(from: 0, to: data.count, by: 4) where data[i + 2] > 20 { count += 1 }
    return count
}

@Test func aRippleDrawsSomething() {
    let ink = inkCount(200) { context in
        ClickRippleRenderer.draw(ClickRipple(position: CGPoint(x: 100, y: 100), frame: 0),
                                 at: 0, in: context)
    }
    #expect(ink > 0)
}

@Test func anExpiredRippleDrawsNothing() {
    let ink = inkCount(200) { context in
        ClickRippleRenderer.draw(ClickRipple(position: CGPoint(x: 100, y: 100), frame: 0),
                                 at: Recording.clickRippleFrames + 5, in: context)
    }
    #expect(ink == 0)
}

@Test func aRippleFadesAsItAges() {
    // The visual point of the effect: it has to be obviously dimmer near the
    // end of its life than at the start.
    let duration = Recording.clickRippleFrames
    let early = inkCount(300) { context in
        ClickRippleRenderer.draw(ClickRipple(position: CGPoint(x: 150, y: 150), frame: 0),
                                 at: 1, in: context)
    }
    let late = inkCount(300) { context in
        ClickRippleRenderer.draw(ClickRipple(position: CGPoint(x: 150, y: 150), frame: 0),
                                 at: duration - 1, in: context)
    }
    #expect(early > 0 && late >= 0)
    // Brightness, not coverage: the ring is larger when old but much fainter.
    #expect(late < early, "an old ripple should be fainter than a fresh one")
}

@Test func anEmptyTrackDrawsNothing() {
    let ink = inkCount(100) { context in
        ClickRippleRenderer.draw(ClickRippleTrack(), at: 0, in: context)
    }
    #expect(ink == 0)
}

// MARK: Output geometry

@Test func theOutputSizeIsEvenForH264() {
    // Odd dimensions are rejected or silently rounded by the encoder, which
    // shows up as a skewed video rather than an error.
    let options = ScreenRecorder.Options(
        region: CGRect(x: 0, y: 0, width: 101.5, height: 55.25),
        scale: 1, displayID: 0)
    let size = options.pixelSize
    #expect(size.width % 2 == 0)
    #expect(size.height % 2 == 0)
}

@Test func theOutputSizeIsInPixelsNotPoints() {
    let options = ScreenRecorder.Options(
        region: CGRect(x: 0, y: 0, width: 200, height: 100),
        scale: 2, displayID: 0)
    #expect(options.pixelSize == (400, 200))
}
