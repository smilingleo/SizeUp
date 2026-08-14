import Testing
import CoreGraphics
import Geometry
import WindowKit
@testable import Core

private let key = WindowKey(pid: 1, elementHash: 1)
private let otherKey = WindowKey(pid: 1, elementHash: 2)
private let leftHalf = CGRect(x: 0, y: 0, width: 1680, height: 1860)

@MainActor
@Test func firstPressIsStepZero() {
    let store = WindowStateStore()
    let step = store.cycleStep(for: key, action: .half(.left), currentFrame: .zero)
    #expect(step == 0)
}

@MainActor
@Test func repeatedPressAdvancesStep() {
    let store = WindowStateStore()
    _ = store.cycleStep(for: key, action: .half(.left), currentFrame: .zero)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: .zero)
    let step = store.cycleStep(for: key, action: .half(.left), currentFrame: leftHalf)
    #expect(step == 1)
}

@MainActor
@Test func differentActionResetsStep() {
    let store = WindowStateStore()
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: .zero)
    let step = store.cycleStep(for: key, action: .half(.right), currentFrame: leftHalf)
    #expect(step == 0)
}

/// Moving the window by hand breaks the chain, so the next press starts over.
@MainActor
@Test func manuallyMovedWindowResetsStep() {
    let store = WindowStateStore()
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: .zero)
    let moved = leftHalf.offsetBy(dx: 40, dy: 0)
    let step = store.cycleStep(for: key, action: .half(.left), currentFrame: moved)
    #expect(step == 0)
}

/// Actions that do not cycle always report step zero, even when repeated.
@MainActor
@Test func nonCyclingActionNeverAdvances() {
    let store = WindowStateStore()
    let quarter = CGRect(x: 0, y: 930, width: 1680, height: 930)
    store.record(key: key, action: .quarter(.upperLeft), achievedFrame: quarter, previousFrame: .zero)
    let step = store.cycleStep(for: key, action: .quarter(.upperLeft), currentFrame: quarter)
    #expect(step == 0)
}

@MainActor
@Test func snapBackReturnsFrameFromBeforeFirstAction() {
    let store = WindowStateStore()
    let original = CGRect(x: 300, y: 300, width: 900, height: 700)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: original)
    #expect(store.snapBackFrame(for: key) == original)
}

/// A second action on an already-managed window must not overwrite the
/// user's original frame — otherwise Snap Back only undoes one step.
@MainActor
@Test func snapBackPreservesOriginalAcrossChainedActions() {
    let store = WindowStateStore()
    let original = CGRect(x: 300, y: 300, width: 900, height: 700)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: original)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: leftHalf)
    #expect(store.snapBackFrame(for: key) == original)
}

/// An app that settles a fraction of a point off its applied frame on a
/// later run-loop turn must still count as "our chain", so `originalFrame`
/// survives and Snap Back returns the true original.
@MainActor
@Test func tinyDriftFromApplicationStillCountsAsOurChain() {
    let store = WindowStateStore()
    let original = CGRect(x: 300, y: 300, width: 900, height: 700)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: original)
    let settled = leftHalf.offsetBy(dx: 0.6, dy: -0.6)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: settled)
    #expect(store.snapBackFrame(for: key) == original)
}

/// But if the user moves the window themselves, that becomes the new origin.
@MainActor
@Test func manualMoveBecomesNewSnapBackOrigin() {
    let store = WindowStateStore()
    let original = CGRect(x: 300, y: 300, width: 900, height: 700)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: original)
    let userPlaced = CGRect(x: 50, y: 60, width: 400, height: 300)
    _ = store.cycleStep(for: key, action: .half(.left), currentFrame: userPlaced)
    store.record(key: key, action: .half(.left), achievedFrame: leftHalf, previousFrame: userPlaced)
    #expect(store.snapBackFrame(for: key) == userPlaced)
}

@MainActor
@Test func snapBackForUnknownWindowIsNil() {
    let store = WindowStateStore()
    #expect(store.snapBackFrame(for: otherKey) == nil)
}

@MainActor
@Test func evictsLeastRecentlyUsedBeyondCapacity() {
    let store = WindowStateStore(capacity: 2)
    let a = WindowKey(pid: 1, elementHash: 1)
    let b = WindowKey(pid: 1, elementHash: 2)
    let c = WindowKey(pid: 1, elementHash: 3)
    store.record(key: a, action: .fullScreen, achievedFrame: leftHalf, previousFrame: .zero)
    store.record(key: b, action: .fullScreen, achievedFrame: leftHalf, previousFrame: .zero)
    // Touch a so b becomes least-recently-used.
    _ = store.snapBackFrame(for: a)
    store.record(key: c, action: .fullScreen, achievedFrame: leftHalf, previousFrame: .zero)
    #expect(store.count == 2)
    #expect(store.snapBackFrame(for: b) == nil)
    #expect(store.snapBackFrame(for: a) != nil)
    #expect(store.snapBackFrame(for: c) != nil)
}
