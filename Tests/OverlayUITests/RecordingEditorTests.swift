import Annotation
import AppKit
import Testing
import VideoEdit
@testable import OverlayUI

// The editor's views are mostly geometry: frame <-> x on the timeline, and the
// letterboxed video rect on the canvas. Both are testable without showing a
// window, and both are places where being slightly wrong means annotations land
// somewhere other than where they were drawn.

private func edit(frames: Int = 300, fps: Double = 30) -> RecordingEdit {
    RecordingEdit(videoURL: URL(fileURLWithPath: "/tmp/x.mp4"),
                  totalFrames: frames, fps: fps)
}

private func timeline(frames: Int = 300, width: CGFloat = 616) -> TimelineView {
    let view = TimelineView(frame: CGRect(x: 0, y: 0, width: width,
                                          height: TimelineView.totalHeight))
    view.edit = edit(frames: frames)
    return view
}

// MARK: Timeline mapping

@MainActor
@Test func theFirstFrameIsAtTheLeftEdgeAndTheLastAtTheRight() {
    // If the ends do not line up, the playhead can never reach the start or the
    // end of the video, which makes trimming the last second impossible.
    let view = timeline()
    let padding = TimelineView.padding
    #expect(abs(view.xForFrameForTesting(0) - padding) < 0.5)
    #expect(abs(view.xForFrameForTesting(299) - (view.bounds.width - padding)) < 0.5)
}

@MainActor
@Test func frameAndXRoundTrip() {
    let view = timeline()
    for frame in [0, 1, 75, 150, 298, 299] {
        let x = view.xForFrameForTesting(frame)
        #expect(view.frameForXForTesting(x) == frame,
                "frame \(frame) mapped to x \(x) and back to \(view.frameForXForTesting(x))")
    }
}

@MainActor
@Test func clicksOutsideTheTrackAreClampedIntoTheVideo() {
    // Dragging the playhead past either edge is normal; it must stop at the ends
    // rather than producing a negative or out-of-range frame.
    let view = timeline()
    #expect(view.frameForXForTesting(-500) == 0)
    #expect(view.frameForXForTesting(5000) == 299)
}

@MainActor
@Test func aSingleFrameVideoDoesNotDivideByZero() {
    let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400,
                                          height: TimelineView.totalHeight))
    view.edit = edit(frames: 1)
    #expect(view.frameForXForTesting(200) == 0)
    #expect(view.xForFrameForTesting(0).isFinite)
}

@MainActor
@Test func aTimelineWithNoDocumentDoesNotCrash() {
    let view = TimelineView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    #expect(view.frameForXForTesting(100) == 0)
    view.draw(view.bounds)
}

// MARK: Annotation spans

@MainActor
@Test func anAnnotationsSpanCoversItsFrames() {
    var document = edit()
    document.add(Annotation(kind: .rect(origin: .zero, size: CGSize(width: 10, height: 10))),
                 at: 100)
    document.setRange(0, start: 100, end: 200)

    let view = timeline()
    view.edit = document
    let span = view.spanRectForTesting(0)
    #expect(abs(span.minX - view.xForFrameForTesting(100)) < 0.5)
    #expect(abs(span.maxX - view.xForFrameForTesting(200)) < 0.5)
}

@MainActor
@Test func anOpenEndedSpanRunsToTheEndOfTheTimeline() {
    var document = edit()
    document.add(Annotation(kind: .rect(origin: .zero, size: CGSize(width: 10, height: 10))),
                 at: 10)
    document.setRange(0, start: 10, end: nil)

    let view = timeline()
    view.edit = document
    let span = view.spanRectForTesting(0)
    #expect(abs(span.maxX - view.xForFrameForTesting(299)) < 1)
}

@MainActor
@Test func aOneFrameSpanIsStillWideEnoughToGrab() {
    // A zero-width span would be invisible and unclickable, so it could never be
    // selected in order to lengthen it.
    var document = edit()
    document.add(Annotation(kind: .rect(origin: .zero, size: CGSize(width: 10, height: 10))),
                 at: 100)
    document.setRange(0, start: 100, end: 101)

    let view = timeline()
    view.edit = document
    #expect(view.spanRectForTesting(0).width >= 2)
}

@MainActor
@Test func spansStayInsideTheLanesArea() {
    // Lanes wrap round-robin; nothing may be drawn over the scrubber, where it
    // would be mistaken for the playhead.
    var document = edit()
    for i in 0..<12 {
        document.add(Annotation(kind: .rect(origin: .zero,
                                            size: CGSize(width: 10, height: 10))),
                     at: i * 10)
    }
    let view = timeline()
    view.edit = document
    for index in 0..<12 {
        let span = view.spanRectForTesting(index)
        #expect(span.minY > TimelineView.padding + TimelineView.scrubberHeight,
                "span \(index) overlapped the scrubber")
    }
}

@MainActor
@Test func drawingTheTimelineWithEveryFeatureAtOnceDoesNotCrash() {
    // Cheap, but it exercises the freeze bands, the pulse caps, the handles and
    // the playhead together, which is the combination the window actually shows.
    var document = edit()
    document.add(Annotation(kind: .rect(origin: .zero, size: CGSize(width: 10, height: 10))),
                 at: 20)
    document.togglePulse(0)
    document.insertFreeze(at: 100, holdFrames: 30)
    document.seek(to: 150)

    let view = timeline()
    view.edit = document
    view.selectedIndex = 0

    let image = NSImage(size: view.bounds.size)
    image.lockFocus()
    view.draw(view.bounds)
    image.unlockFocus()
    #expect(image.size.width > 0)
}

// MARK: Canvas letterboxing

@MainActor
private func canvas(_ size: CGSize) -> RecordingCanvasView {
    let view = RecordingCanvasView(bridge: EditorBridge(edit: edit()))
    view.frame = CGRect(origin: .zero, size: size)
    return view
}

@MainActor
@Test func withNoVideoTheCanvasUsesItsWholeBounds() {
    let view = canvas(CGSize(width: 800, height: 600))
    #expect(view.videoRect == view.bounds)
}

@MainActor
@Test func theCanvasIsFlippedLikeTheCaptureOverlay() {
    // Annotation coordinates mean the same thing in both editors only if both
    // views agree about which way y runs.
    #expect(canvas(CGSize(width: 100, height: 100)).isFlipped)
}

@MainActor
@Test func annotationSpaceMatchesTheVideoArea() {
    // Reported to the exporter as the scale to convert from; if it were the whole
    // view instead, every annotation would be offset by the letterbox bars.
    let view = canvas(CGSize(width: 800, height: 600))
    #expect(view.annotationSpace == view.videoRect.size)
}

@MainActor
@Test func aPointConvertsIntoTheVideosOwnSpace() {
    let view = canvas(CGSize(width: 800, height: 600))
    let origin = view.pointForTesting(.zero)
    #expect(origin == CGPoint(x: view.videoRect.minX, y: view.videoRect.minY))
}
