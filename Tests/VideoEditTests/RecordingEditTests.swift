import Annotation
import CoreGraphics
import Foundation
import Testing
@testable import VideoEdit

// The recording editor's whole job is time, so these tests are about frames:
// which one is on screen, which annotations are alive, and what happens to both
// when a freeze is inserted or the speed changes.

private func edit(frames: Int = 300, fps: Double = 30) -> RecordingEdit {
    RecordingEdit(videoURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                  totalFrames: frames, fps: fps)
}

private func shape(_ rect: CGRect = CGRect(x: 10, y: 10, width: 50, height: 40))
    -> Annotation {
    Annotation(kind: .rect(origin: rect.origin, size: rect.size))
}

// MARK: The three frame spaces

@Test func withNoEditsAllThreeSpacesAgree() {
    // The mappings must be the identity in the simple case, or every later test
    // is measuring compensating errors.
    let e = edit(frames: 100)
    #expect(e.totalFrames == 100)
    for frame in [0, 1, 50, 99] {
        #expect(e.baseFrame(forTimeline: frame) == frame)
        #expect(e.sourceFrame(forTimeline: frame) == frame)
        #expect(e.timelineFrame(forBase: frame) == frame)
    }
}

@Test func theLastFrameMapsToTheLastFrame() {
    // Rounding at the end of the timeline must not walk off the file: asking for
    // a frame past the end is what a scrubber dragged to the far right does.
    let e = edit(frames: 100)
    #expect(e.baseFrame(forTimeline: 99) == 99)
    #expect(e.baseFrame(forTimeline: 500) == 99)
    #expect(e.sourceFrame(forTimeline: 500) == 99)
}

@Test func anEmptyVideoMapsToZeroRatherThanCrashing() {
    let e = edit(frames: 0)
    #expect(e.baseFrame(forTimeline: 0) == 0)
    #expect(e.sourceFrame(forTimeline: 10) == 0)
    #expect(e.timelineFrame(forBase: 10) == 0)
}

// MARK: Playhead

@Test func theSeekIsClampedToTheVideo() {
    var e = edit(frames: 100)
    e.seek(to: -5)
    #expect(e.currentFrame == 0)
    e.seek(to: 999)
    #expect(e.currentFrame == 99)
}

@Test func playbackStopsAtTheEndRatherThanRunningOff() {
    var e = edit(frames: 3)
    e.seek(to: 1)
    let advanced = e.advance()
    #expect(advanced)
    #expect(e.currentFrame == 2)
    let ranOff = e.advance()
    #expect(!ranOff, "advancing past the last frame must report the end")
    #expect(e.currentFrame == 2)
}

@Test func durationIsInOutputSeconds() {
    let e = edit(frames: 90, fps: 30)
    #expect(abs(e.duration - 3) < 0.001)
}

// MARK: Annotation lifespans

@Test func aNewAnnotationLastsOneSecondByDefault() {
    // Not one frame, which would be invisible, and not to the end, which would
    // need trimming every single time.
    var e = edit(frames: 300, fps: 30)
    let index = e.add(shape(), at: 100)
    #expect(e.annotations[index].range.start == 100)
    #expect(e.annotations[index].range.end == 130)
    #expect(e.selected == index, "a fresh annotation is the one being edited")
}

@Test func theDefaultEndIsClampedToTheEndOfTheVideo() {
    var e = edit(frames: 100, fps: 30)
    let index = e.add(shape(), at: 95)
    #expect(e.annotations[index].range.end == 100)
}

@Test func anAnnotationIsAlwaysAtLeastOneFrameLong() {
    var e = edit(frames: 100)
    let index = e.add(shape(), at: 99)
    let range = e.annotations[index].range
    #expect(range.end! > range.start, "a zero-length annotation could never be seen or fixed")
}

@Test func onlyAnnotationsAliveAtTheFrameAreVisible() {
    var e = edit(frames: 300)
    e.add(shape(), at: 0)      // 0..<30
    e.add(shape(), at: 100)    // 100..<130
    #expect(e.annotations(at: 10).count == 1)
    #expect(e.annotations(at: 50).isEmpty, "between the two, nothing shows")
    #expect(e.annotations(at: 110).count == 1)
    #expect(e.annotations(at: 110).first?.index == 1, "indices survive filtering")
}

@Test func anOpenEndedAnnotationRunsToTheEnd() {
    var e = edit(frames: 300)
    e.add(shape(), at: 10)
    e.setRange(0, start: 10, end: nil)
    #expect(e.annotations[0].range.contains(299))
    #expect(!e.annotations[0].range.contains(9))
}

@Test func retimingCannotInvertTheRange() {
    var e = edit(frames: 300)
    e.add(shape(), at: 100)
    e.setRange(0, start: 100, end: 50)
    let range = e.annotations[0].range
    #expect(range.end! > range.start, "an inverted range would silently hide the annotation")
}

// MARK: Selection, hit-testing, undo

@Test func hitTestingOnlyFindsWhatIsOnScreenNow() {
    // Clicking where an annotation *will be* must not select it: the user cannot
    // see it, so the selection would be inexplicable.
    var e = edit(frames: 300)
    e.add(shape(CGRect(x: 0, y: 0, width: 100, height: 100)), at: 200)
    #expect(e.hitTest(CGPoint(x: 50, y: 50), at: 210) == 0)
    #expect(e.hitTest(CGPoint(x: 50, y: 50), at: 10) == nil)
}

@Test func hitTestingPrefersTheTopmost() {
    var e = edit(frames: 300)
    e.add(shape(CGRect(x: 0, y: 0, width: 100, height: 100)), at: 0)
    e.add(shape(CGRect(x: 0, y: 0, width: 100, height: 100)), at: 0)
    #expect(e.hitTest(CGPoint(x: 50, y: 50), at: 5) == 1, "the last drawn is on top")
}

@Test func selectingOutOfRangeClearsRatherThanCrashes() {
    var e = edit()
    e.add(shape(), at: 0)
    e.select(7)
    #expect(e.selected == nil)
}

@Test func undoRemovesTheSelectedAnnotationNotJustTheLast() {
    // The screenshot editor pops the newest; here the user can select an older
    // one, and undoing must take what they are pointing at.
    var e = edit(frames: 300)
    e.add(shape(), at: 0)
    e.add(shape(), at: 100)
    e.select(0)
    e.undo()
    #expect(e.annotations.count == 1)
    #expect(e.annotations[0].range.start == 100, "the newer one survived")
}

@Test func undoWithNoSelectionTakesTheMostRecent() {
    var e = edit(frames: 300)
    e.add(shape(), at: 0)
    e.add(shape(), at: 100)
    e.select(nil)
    e.undo()
    #expect(e.annotations.count == 1)
    #expect(e.annotations[0].range.start == 0)
}

@Test func redoPutsItBack() {
    var e = edit(frames: 300)
    e.add(shape(), at: 42)
    e.undo()
    #expect(e.annotations.isEmpty)
    let redone = e.redo()
    #expect(redone)
    #expect(e.annotations.count == 1)
    #expect(e.annotations[0].range.start == 42, "the lifespan came back too")
}

@Test func redoOnAnEmptyStackIsRefused() {
    var e = edit()
    let redone = e.redo()
    #expect(!redone)
}

@Test func addingClearsTheRedoStack() {
    // Otherwise a redo after new work resurrects an annotation from an abandoned
    // branch of history, which looks like the app inventing shapes.
    var e = edit(frames: 300)
    e.add(shape(), at: 0)
    e.undo()
    e.add(shape(), at: 100)
    let redone = e.redo()
    #expect(!redone)
}

@Test func pulseIsOffUntilAskedFor() {
    var e = edit(frames: 300)
    e.add(shape(), at: 0)
    #expect(!e.annotations[0].pulses)
    e.togglePulse(0)
    #expect(e.annotations[0].pulses)
}

// MARK: Freeze

@Test func aFreezeLengthensTheVideo() {
    var e = edit(frames: 100, fps: 30)
    let insertedFrames = e.insertFreeze(at: 50, holdFrames: 30)
    #expect(insertedFrames == 30)
    #expect(e.totalFrames == 130)
}

@Test func aFrozenSpanShowsTheSameSourceFrameThroughout() {
    // This is what makes a freeze a freeze: every frame in the hold decodes to
    // one source frame.
    var e = edit(frames: 100, fps: 30)
    let source = e.sourceFrame(forTimeline: 50)
    e.insertFreeze(at: 50, holdFrames: 30)
    for frame in 51...79 {
        #expect(e.sourceFrame(forTimeline: frame) == source,
                "frame \(frame) of the hold showed a different source frame")
    }
}

@Test func theVideoResumesAfterAFreeze() {
    // The frames after the hold must continue from where they left off, not
    // restart or skip the length of the hold.
    var e = edit(frames: 100, fps: 30)
    e.insertFreeze(at: 50, holdFrames: 30)
    #expect(e.sourceFrame(forTimeline: 81) == 51)
    #expect(e.sourceFrame(forTimeline: 129) == 99, "the tail still reaches the last frame")
}

@Test func aFreezeShiftsLaterAnnotationsAlong() {
    // A label pinned to a moment must stay on that moment when time is inserted
    // before it.
    var e = edit(frames: 300, fps: 30)
    e.add(shape(), at: 200)
    let before = e.sourceFrame(forTimeline: 200)
    e.insertFreeze(at: 50, holdFrames: 30)
    #expect(e.annotations[0].range.start == 230)
    #expect(e.sourceFrame(forTimeline: 230) == before,
            "the annotation is over the same picture as before")
}

@Test func aFreezeLeavesEarlierAnnotationsAlone() {
    var e = edit(frames: 300, fps: 30)
    e.add(shape(), at: 10)
    e.insertFreeze(at: 200, holdFrames: 30)
    #expect(e.annotations[0].range.start == 10)
}

@Test func anAnnotationAtTheFreezePointIsHeldWithIt() {
    // Freezing *at* a label is how you hold a label on screen, so it must not be
    // pushed past the hold it was meant to fill.
    var e = edit(frames: 300, fps: 30)
    e.add(shape(), at: 100)
    e.insertFreeze(at: 100, holdFrames: 60)
    #expect(e.annotations[0].range.start == 100)
}

@Test func anAnnotationDrawnInsideAFreezeLastsTheWholeFreeze() {
    // Inside a hold the picture is not moving, so one second is the wrong
    // default: the annotation should cover the pause.
    var e = edit(frames: 300, fps: 30)
    e.insertFreeze(at: 100, holdFrames: 90)
    let index = e.add(shape(), at: 120)
    #expect(e.annotations[index].range.end == 191)
}

@Test func aZeroLengthFreezeIsRefused() {
    var e = edit(frames: 100)
    let inserted = e.insertFreeze(at: 50, holdFrames: 0)
    #expect(inserted == 0)
    #expect(e.totalFrames == 100)
}

@Test func removingAFreezeRestoresTheLength() {
    var e = edit(frames: 100, fps: 30)
    e.insertFreeze(at: 50, holdFrames: 30)
    let removed = e.removeFreeze(at: 60)
    #expect(removed)
    #expect(e.totalFrames == 100)
    #expect(e.freezes.isEmpty)
    // And the source mapping is the identity again.
    #expect(e.sourceFrame(forTimeline: 60) == 60)
}

@Test func removingAFreezeWhereThereIsNoneIsRefused() {
    var e = edit(frames: 100)
    let removed = e.removeFreeze(at: 50)
    #expect(!removed)
}

@Test func freezesStayInOrderWhenInsertedOutOfOrder() {
    // The source mapping walks the list and breaks early, so an unsorted list
    // silently returns the wrong frame.
    var e = edit(frames: 300, fps: 30)
    e.insertFreeze(at: 200, holdFrames: 30)
    e.insertFreeze(at: 50, holdFrames: 30)
    #expect(e.freezes.map(\.atBaseFrame) == e.freezes.map(\.atBaseFrame).sorted())
    #expect(e.sourceFrame(forTimeline: 51) == 50)
}

@Test func twoFreezesBothHold() {
    var e = edit(frames: 300, fps: 30)
    e.insertFreeze(at: 50, holdFrames: 30)
    e.insertFreeze(at: 200, holdFrames: 30)
    #expect(e.totalFrames == 360)
    #expect(e.sourceFrame(forTimeline: 60) == 50, "the first hold")
    #expect(e.sourceFrame(forTimeline: 210) == e.sourceFrame(forTimeline: 205),
            "the second hold")
}

// MARK: Speed

@Test func doubleSpeedHalvesTheTimeline() {
    var e = edit(frames: 300, fps: 30)
    e.setPlaybackSpeed(2)
    #expect(e.totalFrames == 150)
    #expect(abs(e.duration - 5) < 0.001)
}

@Test func halfSpeedDoublesTheTimeline() {
    var e = edit(frames: 300, fps: 30)
    e.setPlaybackSpeed(0.5)
    #expect(e.totalFrames == 600)
}

@Test func speedRemapsWhichSourceFrameIsShown() {
    var e = edit(frames: 300, fps: 30)
    e.setPlaybackSpeed(2)
    #expect(e.sourceFrame(forTimeline: 50) == 100, "at 2x, output frame 50 is source 100")
}

@Test func annotationsKeepTheirMomentWhenSpeedChanges() {
    // Stored in timeline frames, so leaving them alone at 2x would slide every
    // annotation to a different part of the video.
    var e = edit(frames: 300, fps: 30)
    e.add(shape(), at: 100)
    let sourceBefore = e.sourceFrame(forTimeline: 100)
    e.setPlaybackSpeed(2)
    #expect(e.annotations[0].range.start == 50)
    #expect(e.sourceFrame(forTimeline: 50) == sourceBefore)
}

@Test func annotationsSurviveARoundTripThroughSpeed() {
    var e = edit(frames: 300, fps: 30)
    e.add(shape(), at: 120)
    e.setRange(0, start: 120, end: 180)
    e.setPlaybackSpeed(2)
    e.setPlaybackSpeed(1)
    #expect(e.annotations[0].range.start == 120)
    #expect(e.annotations[0].range.end == 180)
    #expect(e.totalFrames == 300)
}

@Test func theSpeedChangeCarriesThePlayheadWithIt() {
    // The user is looking at a moment; changing speed should not jump them
    // somewhere else in the video.
    var e = edit(frames: 300, fps: 30)
    e.seek(to: 100)
    let source = e.sourceFrame(forTimeline: 100)
    e.setPlaybackSpeed(2)
    #expect(e.currentFrame == 50)
    #expect(e.sourceFrame(forTimeline: e.currentFrame) == source)
}

@Test func aSpeedOfZeroCannotDivideByZero() {
    // Guards the whole frame-mapping layer: every mapping divides by speed.
    var e = edit(frames: 300, fps: 30)
    e.setPlaybackSpeed(0)
    #expect(e.totalFrames > 0)
    #expect(e.sourceFrame(forTimeline: 0) >= 0)
    #expect(e.playbackSpeed >= 0.1)
}

@Test func annotationRangesStayInsideTheVideoAtHigherSpeed() {
    var e = edit(frames: 300, fps: 30)
    e.add(shape(), at: 290)
    e.setPlaybackSpeed(2)
    let range = e.annotations[0].range
    #expect(range.start < e.totalFrames)
    #expect(range.end! <= e.totalFrames)
}

@Test func freezeAndSpeedCompose() {
    // The two features multiply into the same frame math, and this is the case
    // where an off-by-one in either shows up.
    var e = edit(frames: 300, fps: 30)
    e.insertFreeze(at: 100, holdFrames: 60)
    #expect(e.totalFrames == 360)
    e.setPlaybackSpeed(2)
    #expect(e.totalFrames == 180)
    // The hold is still a hold, just half as long in output frames.
    let inHold = e.sourceFrame(forTimeline: 55)
    #expect(e.sourceFrame(forTimeline: 60) == inHold)
}

// MARK: Dirty tracking

@Test func aFreshEditHasNothingToLose() {
    #expect(!edit().hasEdits)
}

@Test func anyEditIsWorthWarningAbout() {
    var withAnnotation = edit(frames: 300)
    withAnnotation.add(shape(), at: 0)
    #expect(withAnnotation.hasEdits)

    var withFreeze = edit(frames: 300)
    withFreeze.insertFreeze(at: 10, holdFrames: 10)
    #expect(withFreeze.hasEdits)

    var withSpeed = edit(frames: 300)
    withSpeed.setPlaybackSpeed(2)
    #expect(withSpeed.hasEdits)
}
