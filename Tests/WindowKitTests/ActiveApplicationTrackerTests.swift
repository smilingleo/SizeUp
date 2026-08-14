import Testing
import Darwin
@testable import WindowKit

private struct FakeRunningApplication: RunningApplicationLike, Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

@MainActor
@Test func trackerTargetsThePreviouslyActiveAppNotTheCurrentlyFrontmostOne() {
    let tracker = ActiveApplicationTracker(
        ownBundleIdentifier: "com.lliu.sizeup2",
        ownProcessIdentifier: 999
    )

    let editor = FakeRunningApplication(processIdentifier: 1, bundleIdentifier: "com.example.editor")
    tracker.noteActivation(of: editor)

    // Simulate the menu path: clicking a status-item entry activates
    // Sizeup2 itself, which is "frontmost" at the moment an action runs.
    let sizeup2 = FakeRunningApplication(processIdentifier: 999, bundleIdentifier: "com.lliu.sizeup2")
    tracker.noteActivation(of: sizeup2)

    let target = tracker.current as? FakeRunningApplication
    #expect(target == editor)
}

@MainActor
@Test func trackerExcludesSelfByBundleIdentifierEvenIfPidDiffers() {
    let tracker = ActiveApplicationTracker(
        ownBundleIdentifier: "com.lliu.sizeup2",
        ownProcessIdentifier: 999
    )

    let editor = FakeRunningApplication(processIdentifier: 1, bundleIdentifier: "com.example.editor")
    tracker.noteActivation(of: editor)

    // Same bundle identifier, different pid than the one we were
    // constructed with -- still must not overwrite the tracked target.
    let impersonator = FakeRunningApplication(processIdentifier: 42, bundleIdentifier: "com.lliu.sizeup2")
    tracker.noteActivation(of: impersonator)

    let target = tracker.current as? FakeRunningApplication
    #expect(target == editor)
}

@MainActor
@Test func trackerUpdatesAcrossMultipleOtherAppActivations() {
    let tracker = ActiveApplicationTracker(
        ownBundleIdentifier: "com.lliu.sizeup2",
        ownProcessIdentifier: 999
    )

    let editor = FakeRunningApplication(processIdentifier: 1, bundleIdentifier: "com.example.editor")
    let browser = FakeRunningApplication(processIdentifier: 2, bundleIdentifier: "com.example.browser")
    tracker.noteActivation(of: editor)
    tracker.noteActivation(of: browser)

    let target = tracker.current as? FakeRunningApplication
    #expect(target == browser)
}
