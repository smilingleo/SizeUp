import CoreGraphics
import Testing
@testable import VideoEdit

private let bar = MiniBarLayout(
    bounds: CGRect(x: 0, y: 0, width: MiniBarLayout.width, height: MiniBarLayout.height))

// MARK: Layout

@Test func theButtonsSitInsideTheBarAndDoNotOverlap() {
    let done = bar.doneButton, pulse = bar.pulseButton, hold = bar.holdButton
    #expect(done.maxX <= bar.bounds.maxX)
    #expect(hold.minX > bar.bounds.minX)
    #expect(hold.maxX <= pulse.minX)
    #expect(pulse.maxX <= done.minX)
    for rect in [done, pulse, hold] {
        #expect(rect.minY >= 0)
        #expect(rect.maxY <= bar.bounds.height)
    }
}

@Test func theTrackStopsShortOfTheButtons() {
    // Otherwise dragging the end handle to the far right would be a click on Hold.
    #expect(bar.track.width > 0)
    #expect(bar.track.maxX <= bar.holdButton.minX)
}

@Test func theTrackEndsMapToTheFirstAndLastFrame() {
    #expect(abs(bar.x(forFrame: 0, totalFrames: 300) - bar.track.minX) < 0.5)
    #expect(abs(bar.x(forFrame: 299, totalFrames: 300) - bar.track.maxX) < 0.5)
}

@Test func frameAndXRoundTripOnTheMiniBar() {
    for frame in [0, 1, 100, 298, 299] {
        let x = bar.x(forFrame: frame, totalFrames: 300)
        #expect(bar.frame(forX: x, totalFrames: 300) == frame)
    }
}

@Test func positionsOutsideTheTrackClampIntoTheRecording() {
    #expect(bar.frame(forX: -200, totalFrames: 300) == 0)
    #expect(bar.frame(forX: 9999, totalFrames: 300) == 299)
}

@Test func aSingleFrameRecordingDoesNotDivideByZero() {
    #expect(bar.frame(forX: 100, totalFrames: 1) == 0)
    #expect(bar.x(forFrame: 0, totalFrames: 1).isFinite)
}

@Test func aSpanIsAlwaysWideEnoughToSee() {
    let span = bar.spanRect(start: 100, end: 100, totalFrames: 300)
    #expect(span.width >= 1)
}

// MARK: Hit testing

@Test func theButtonsAreHit() {
    let total = 300
    #expect(bar.hit(CGPoint(x: bar.doneButton.midX, y: bar.doneButton.midY),
                    start: 0, end: 10, totalFrames: total) == .done)
    #expect(bar.hit(CGPoint(x: bar.pulseButton.midX, y: bar.pulseButton.midY),
                    start: 0, end: 10, totalFrames: total) == .pulse)
    #expect(bar.hit(CGPoint(x: bar.holdButton.midX, y: bar.holdButton.midY),
                    start: 0, end: 10, totalFrames: total) == .hold)
}

@Test func theHandlesWinOverTheTrackTheyOverlap() {
    // The handles sit on top of the track, so a press on one has to be a drag,
    // not a scrub -- otherwise a span could never be retimed.
    let total = 300
    let start = 60, end = 200
    let onStart = CGPoint(x: bar.x(forFrame: start, totalFrames: total), y: bar.track.midY)
    let onEnd = CGPoint(x: bar.x(forFrame: end, totalFrames: total), y: bar.track.midY)
    #expect(bar.hit(onStart, start: start, end: end, totalFrames: total) == .startHandle)
    #expect(bar.hit(onEnd, start: start, end: end, totalFrames: total) == .endHandle)
}

@Test func aPressInTheMiddleOfTheTrackScrubs() {
    let total = 300
    let x = bar.x(forFrame: 150, totalFrames: total)
    let hit = bar.hit(CGPoint(x: x, y: bar.track.midY), start: 0, end: 10,
                      totalFrames: total)
    #expect(hit == .track(frame: 150))
}

@Test func aCollapsedSpanCanStillBeLengthened() {
    // Both handles land on the same pixel; the end must be the one that answers,
    // or a one-frame annotation is stuck at one frame forever.
    let total = 300
    let x = bar.x(forFrame: 100, totalFrames: total)
    let hit = bar.hit(CGPoint(x: x, y: bar.track.midY), start: 100, end: 100,
                      totalFrames: total)
    #expect(hit == .endHandle)
}

@Test func aPressOnEmptyChromeDoesNothing() {
    #expect(bar.hit(CGPoint(x: 2, y: 18), start: 0, end: 10, totalFrames: 300) == .none)
}

// MARK: Placement

private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)

@Test func theBarIsCentredVisuallyBelowTheShape() {
    // y-up space, so "below" is a smaller y. Getting this backwards puts the bar
    // on top of whatever the shape is drawing attention to.
    let shape = CGRect(x: 400, y: 300, width: 200, height: 100)
    let origin = MiniBarLayout.origin(under: shape, in: canvas)
    #expect(abs(origin.x + MiniBarLayout.width / 2 - shape.midX) < 0.5)
    #expect(origin.y < shape.minY, "the bar was not below the shape")
    #expect(abs(origin.y + MiniBarLayout.height + MiniBarLayout.gap - shape.minY) < 0.5)
}

@Test func theBarFlipsAboveAShapeAtTheBottomEdge() {
    // "Below" is only a preference: at the edge the bar would be off-screen.
    let shape = CGRect(x: 400, y: 4, width: 200, height: 40)
    let origin = MiniBarLayout.origin(under: shape, in: canvas)
    #expect(origin.y >= canvas.minY)
    #expect(origin.y > shape.minY, "the bar should have flipped above the shape")
}

@Test func theBarStaysInsideTheCanvasHorizontally() {
    for shape in [CGRect(x: -50, y: 300, width: 40, height: 40),
                  CGRect(x: 980, y: 300, width: 40, height: 40)] {
        let origin = MiniBarLayout.origin(under: shape, in: canvas)
        #expect(origin.x >= canvas.minX)
        #expect(origin.x + MiniBarLayout.width <= canvas.maxX + 0.5,
                "the bar hung off the right edge for \(shape)")
    }
}

@Test func theBarFitsEvenInACanvasNarrowerThanItself() {
    // Degenerate, but it must not produce a NaN or an origin outside the window.
    let tiny = CGRect(x: 0, y: 0, width: 120, height: 80)
    let origin = MiniBarLayout.origin(under: CGRect(x: 10, y: 10, width: 20, height: 20),
                                      in: tiny)
    #expect(origin.x.isFinite)
    #expect(origin.y.isFinite)
    #expect(origin.x >= tiny.minX)
}

@Test func theHoldMenuOffersMoreThanOneDuration() {
    #expect(MiniBarLayout.holdChoices.count > 1)
    #expect(MiniBarLayout.holdChoices.allSatisfy { $0 > 0 })
    #expect(MiniBarLayout.holdChoices == MiniBarLayout.holdChoices.sorted())
}
