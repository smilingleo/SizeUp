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

@MainActor
@Test func retainedPlacementReportsWhatTheWindowIsStillHolding() {
    let store = WindowStateStore()
    let key = WindowKey(pid: 501, elementHash: 1)
    let applied = CGRect(x: 0, y: 0, width: 1680, height: 1860)

    store.record(key: key, action: .half(.left), achievedFrame: applied,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))

    let placement = store.retainedPlacement(for: key, currentFrame: applied)
    #expect(placement?.action == .half(.left))
    #expect(placement?.step == 0)
}

@MainActor
@Test func retainedPlacementIsNilOnceTheUserMovesTheWindow() {
    let store = WindowStateStore()
    let key = WindowKey(pid: 501, elementHash: 1)
    let applied = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    store.record(key: key, action: .half(.left), achievedFrame: applied,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))

    let dragged = CGRect(x: 400, y: 400, width: 1680, height: 1860)
    #expect(store.retainedPlacement(for: key, currentFrame: dragged) == nil)
}

@MainActor
@Test func retainedPlacementCarriesTheCycleStep() {
    let store = WindowStateStore()
    let key = WindowKey(pid: 501, elementHash: 1)
    let first = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let second = CGRect(x: 0, y: 0, width: 2240, height: 1860)

    store.record(key: key, action: .half(.left), achievedFrame: first,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))
    store.record(key: key, action: .half(.left), achievedFrame: second, previousFrame: first)

    #expect(store.retainedPlacement(for: key, currentFrame: second)?.step == 1)
}

@MainActor
@Test func recordingWithAnExplicitStepDoesNotAdvanceTheCycle() {
    // A display move re-applies the same action on a new screen. That must
    // preserve the window's size, not advance it to the next span.
    let store = WindowStateStore()
    let key = WindowKey(pid: 501, elementHash: 1)
    let onBuiltIn = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    let onExternal = CGRect(x: 3360, y: -838, width: 1028, height: 1291)

    store.record(key: key, action: .half(.left), achievedFrame: onBuiltIn,
                 previousFrame: CGRect(x: 100, y: 100, width: 800, height: 600))
    store.record(key: key, action: .half(.left), achievedFrame: onExternal,
                 previousFrame: onBuiltIn, step: 0)

    #expect(store.retainedPlacement(for: key, currentFrame: onExternal)?.step == 0)
    // The other regression a display move can cause: the pre-tiling frame
    // being clobbered by the intermediate frame the window held on display A.
    #expect(store.snapBackFrame(for: key) == CGRect(x: 100, y: 100, width: 800, height: 600))
}

@MainActor
@Test func retainedPlacementIsNilForAnUnknownWindow() {
    let store = WindowStateStore()
    let key = WindowKey(pid: 999, elementHash: 42)
    #expect(store.retainedPlacement(for: key, currentFrame: .zero) == nil)
}

@MainActor
@Test func recordClampsANegativeExplicitStep() {
    // `step` is public and callers index `spans[step % count]`, where a
    // negative value traps rather than misbehaving.
    let store = WindowStateStore()
    let key = WindowKey(pid: 502, elementHash: 2)
    let applied = CGRect(x: 0, y: 0, width: 1680, height: 1860)
    store.record(key: key, action: .half(.left), achievedFrame: applied,
                 previousFrame: CGRect(x: 1, y: 1, width: 10, height: 10), step: -5)
    #expect(store.retainedPlacement(for: key, currentFrame: applied)?.step == 0)
}
