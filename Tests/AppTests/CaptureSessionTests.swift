import Core
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
