import Annotation
import AppKit
import Capture
import Core
import OverlayUI
import Testing
@testable import App

// Task 5, Step 1's tests. The state machine is `Core`'s `CaptureStateMachine`
// (see the note on that type for why it is not in `App`); `App`'s
// `CaptureSession` is the thin AppKit shell around it and rides the manual
// checklist. What is covered here is the exclusion table the design calls out:
// one function of (mode, event, capabilities), fakes for the collaborators.

@Test func captureFromIdleStartsTheOverlay() {
    var machine = CaptureStateMachine(capabilities: .screenshot)
    #expect(machine.mode == .idle)

    let effect = machine.handle(.screenshotRequested)

    #expect(machine.mode == .capturing)
    #expect(effect == .beginCapture)
}

@Test func captureWhileRecordingIsIgnored() {
    // The design's headline exclusion: no screenshot while recording.
    var machine = CaptureStateMachine(mode: .recording, capabilities: [.screenshot, .recording])

    let effect = machine.handle(.screenshotRequested)

    #expect(machine.mode == .recording)
    #expect(effect == .refused)
}

@Test func aSecondScreenshotPressInCapturingIsIgnored() {
    var machine = CaptureStateMachine(capabilities: .screenshot)
    _ = machine.handle(.screenshotRequested)
    #expect(machine.mode == .capturing)

    // A doubled hotkey must not stack a second overlay.
    #expect(machine.handle(.screenshotRequested) == .refused)
    #expect(machine.mode == .capturing)
}

@Test func confirmReturnsToIdleAndFiresTheCallbackExactlyOnce() {
    var machine = CaptureStateMachine(capabilities: .screenshot)
    _ = machine.handle(.screenshotRequested)

    let first = machine.handle(.overlayConfirmed)
    #expect(machine.mode == .idle)
    #expect(first == .dismissAndCopy)

    // A stale second confirm (double Return) is a no-op, not a fault.
    let second = machine.handle(.overlayConfirmed)
    #expect(machine.mode == .idle)
    #expect(second == .none)
}

@Test func cancelDoesNotFireTheCallback() {
    var machine = CaptureStateMachine(capabilities: .screenshot)
    _ = machine.handle(.screenshotRequested)

    let effect = machine.handle(.overlayCancelled)

    #expect(machine.mode == .idle)
    #expect(effect == .dismiss)
}

@Test func recordAndScrollBeforeC3AreNoOpsThatDoNotChangeState() {
    // C1's honest absence: with only screenshot enabled, the record and scroll
    // requests resolve to `notYetAvailable` (the "coming in a later build"
    // alert in App) and the mode does not move.
    var machine = CaptureStateMachine(capabilities: .screenshot)

    #expect(machine.handle(.recordRequested) == .notYetAvailable)
    #expect(machine.mode == .idle)
    #expect(machine.handle(.scrollRequested) == .notYetAvailable)
    #expect(machine.mode == .idle)
}

@Test func whenRecordingIsEnabledTheRequestStartsRecording() {
    // The same request, a later milestone's capabilities: the table already
    // knows what to do, so C3 is a set change, not a table change.
    var machine = CaptureStateMachine(capabilities: [.screenshot, .recording])

    let effect = machine.handle(.recordRequested)

    #expect(machine.mode == .recording)
    #expect(effect == .beginRecording)

    // Stopping returns to idle and fires the stop.
    #expect(machine.handle(.recordingStopped) == .stopRecording)
    #expect(machine.mode == .idle)
}

@Test func theEditorExcludesScreenshotAndRecordingButNotItself() {
    var machine = CaptureStateMachine(mode: .editing, capabilities: [.screenshot, .recording, .editing])

    #expect(machine.handle(.screenshotRequested) == .refused)
    #expect(machine.handle(.recordRequested) == .refused)
    #expect(machine.mode == .editing)

    #expect(machine.handle(.editorClosed) == .none)
    #expect(machine.mode == .idle)
}

@Test func screenshotIsExcludedWhileScrollCapturing() {
    var machine = CaptureStateMachine(mode: .scrollCapturing, capabilities: [.screenshot, .scrollCapture])

    #expect(machine.handle(.screenshotRequested) == .refused)
    #expect(machine.mode == .scrollCapturing)
}

@Test func aFailedCaptureResetsToIdleViaTheRecoveryHook() {
    // The machine advanced to .capturing before the pipeline ran; a failure
    // (no permission, no display, no image) is the orchestrator's to detect,
    // and `resetToIdle` is its recovery path.
    var machine = CaptureStateMachine(capabilities: .screenshot)
    _ = machine.handle(.screenshotRequested)
    #expect(machine.mode == .capturing)

    machine.resetToIdle()
    #expect(machine.mode == .idle)

    // And the session can start over cleanly.
    #expect(machine.handle(.screenshotRequested) == .beginCapture)
    #expect(machine.mode == .capturing)
}

// MARK: The save dialog must not open behind the overlay

// The overlay and its toolbar sit above every ordinary window, so a save panel
// presented while they are up is invisible and unreachable: the capture looks
// frozen with no way to cancel. The panel is modal, so a test cannot observe it
// directly -- `presentSavePanel` is the seam that makes the *ordering*
// observable instead.

@MainActor
private func sessionReadyToSave() -> (CaptureSession, OverlayView) {
    let session = CaptureSession(capabilities: .screenshot)
    session.activateForPanel = {}          // never steal focus from the runner
    let window = OverlayWindow(displayFrame: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1)
    window.overlayView.setScreenshot(NSImage(size: NSSize(width: 200, height: 200)), scale: 1)
    session.installOverlayForTesting(window)
    window.overlayView.selectRegionForTesting(CGRect(x: 10, y: 10, width: 100, height: 80))
    return (session, window.overlayView)
}

@Test @MainActor func theOverlayIsGoneBeforeTheSavePanelAppears() {
    let (session, view) = sessionReadyToSave()
    var overlayStillUp: Bool?
    session.presentSavePanel = { _ in
        overlayStillUp = session.hasOverlayForTesting
        return nil
    }
    session.overlayViewDidSave(view)

    let seen = try! #require(overlayStillUp, "the save panel was never presented")
    #expect(!seen, "the dialog would have opened behind the overlay")
}

@Test @MainActor func theSavePanelStillReceivesTheFlattenedImage() {
    // Taking the overlay down early must not cost us the pixels: they are read
    // through the overlay, so the order is flatten, then dismiss, then present.
    let (session, view) = sessionReadyToSave()
    view.attach(Annotation(kind: .highlight(origin: CGPoint(x: 20, y: 20),
                                            size: CGSize(width: 40, height: 30)),
                           color: AnnotationColor.choices[0]))
    var received: CGImage?
    session.presentSavePanel = { image in received = image; return nil }
    session.overlayViewDidSave(view)

    let image = try! #require(received, "no image reached the save panel")
    #expect(image.width == 100 && image.height == 80)
}

@Test @MainActor func cancellingTheSavePanelStillEndsTheCapture() {
    let (session, view) = sessionReadyToSave()
    session.presentSavePanel = { _ in nil }        // the user pressed Cancel
    session.overlayViewDidSave(view)
    #expect(!session.hasOverlayForTesting)
}
