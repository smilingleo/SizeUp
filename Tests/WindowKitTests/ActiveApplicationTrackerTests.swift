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

/// Regression test for the launch-time gap: Sizeup2 is `LSUIElement`, so
/// launching it never triggers a `didActivateApplicationNotification` for
/// whatever app was already frontmost. Without seeding, `current` would
/// stay nil until the user manually switched apps, and every hotkey would
/// be dead in the meantime -- this is the exact scenario that hits on every
/// manual launch, since launch-at-login is not implemented.
@MainActor
@Test func trackerReportsFrontmostAppBeforeAnyActivationNotification() {
    let editor = FakeRunningApplication(processIdentifier: 1, bundleIdentifier: "com.example.editor")
    let tracker = ActiveApplicationTracker(
        ownBundleIdentifier: "com.lliu.sizeup2",
        ownProcessIdentifier: 999,
        initialFrontmostApplication: editor
    )

    // No noteActivation call happened yet -- this is the state immediately
    // after construction, before any notification could possibly arrive.
    let target = tracker.current as? FakeRunningApplication
    #expect(target == editor)
}

/// If the OS reports Sizeup2 itself as frontmost at launch -- plausible
/// right after activation completes -- the seed must still be filtered by
/// the same self-exclusion logic as any other activation, not bypass it.
@MainActor
@Test func trackerDoesNotSeedItselfAsTheInitialFrontmostApp() {
    let sizeup2 = FakeRunningApplication(processIdentifier: 999, bundleIdentifier: "com.lliu.sizeup2")
    let tracker = ActiveApplicationTracker(
        ownBundleIdentifier: "com.lliu.sizeup2",
        ownProcessIdentifier: 999,
        initialFrontmostApplication: sizeup2
    )

    #expect(tracker.current == nil)
}
