import CoreGraphics
import Testing
@testable import WindowKit

/// A window that does as it is told, to establish the cost of the common case.
private final class Cooperative {
    var frame: CGRect
    var positionWrites = 0
    var sizeWrites = 0
    var pauses = 0

    init(_ frame: CGRect) { self.frame = frame }

    func applier() -> FrameApplier {
        FrameApplier(
            read: { self.frame },
            writePosition: { self.positionWrites += 1; self.frame.origin = $0 },
            writeSize: { self.sizeWrites += 1; self.frame.size = $0 },
            pause: { self.pauses += 1 }
        )
    }
}

@Test func aCooperativeWindowIsAskedOnceAndNotWaitedFor() {
    let window = Cooperative(CGRect(x: 0, y: 0, width: 100, height: 100))
    let target = CGRect(x: 10, y: 20, width: 300, height: 400)

    let result = window.applier().apply(target)

    #expect(result.frame == target)
    #expect(result.attemptsUsed == 1)
    // The whole point of returning early: no retry, and above all no sleeping
    // on the main thread for a window that already complied.
    #expect(window.pauses == 0)
    // Position, size, position. The trailing write is what fixes a window left
    // mispositioned by a clamped size.
    #expect(window.positionWrites == 2)
    #expect(window.sizeWrites == 1)
}

/// Slack, as the log actually recorded it.
///
/// The first version of this double was wrong in a way worth keeping a note
/// about, because it would have justified a fix that cannot work. It assumed
/// Slack validated the height against the display it *believed* it was on, and
/// that the belief caught up once the window had been moved — which made
/// retrying look like the answer.
///
/// The log says otherwise. In the failing line the window was asked to change
/// size at an unchanged Cocoa position, and the Accessibility position did
/// change (-825 to -1395, since Accessibility measures the top edge and the
/// requested height differed). The position write took. The size write did not,
/// and no amount of asking again would have changed that: Slack's height was
/// 1290 in every one of the forty logged lines, on both displays, and 1290 is
/// the usable height of the small display.
///
/// So this models what was observed and nothing more: a size whose height
/// exceeds a fixed limit is ignored outright — both dimensions, not clamped —
/// while position writes are honoured.
private final class RefusesToGrow {
    static let heightLimit: CGFloat = 1290

    var frame: CGRect
    var pauses = 0

    init(_ frame: CGRect) { self.frame = frame }

    func applier() -> FrameApplier {
        FrameApplier(
            read: { self.frame },
            writePosition: { self.frame.origin = $0 },
            writeSize: { size in
                guard size.height <= Self.heightLimit else { return }
                self.frame.size = size
            },
            pause: { self.pauses += 1 }
        )
    }
}

@Test func aWindowThatRefusesAHeightIsNotTalkedIntoItByRetrying() {
    // Exactly the failing line, in Accessibility space.
    let window = RefusesToGrow(CGRect(x: -3360, y: -825, width: 2056, height: 1290))
    let target = CGRect(x: -3360, y: -1395, width: 1120, height: 1860)

    let result = window.applier().apply(target)

    // Retrying does not win here, and the test says so rather than pretending.
    // What it buys is that the caller and the log know: three attempts, and the
    // frame reported back is the real one, not the one that was asked for.
    #expect(result.attemptsUsed == 3)
    #expect(result.frame == CGRect(x: -3360, y: -1395, width: 2056, height: 1290))
    // One per attempt: each attempt that misses looks again after a pause,
    // because an application still relayouting reads back mid-move.
    #expect(window.pauses == 3)
}

@Test func aRefusedSizeStillLeavesTheWindowWhereItWasAskedToGo() {
    // The consolation prize, and it is a real one: the window is top-aligned in
    // the region it was sent to, because Accessibility positions the top edge
    // and the trailing position write lands after the size was rejected. This
    // is why the reported Cocoa y was 1434 rather than 864 — arithmetic, not a
    // second bug.
    let window = RefusesToGrow(CGRect(x: 0, y: 0, width: 2056, height: 1290))
    let target = CGRect(x: -3360, y: -1395, width: 1120, height: 1860)

    let result = window.applier().apply(target)

    #expect(result.frame?.origin == target.origin)
    let primaryHeight: CGFloat = 1329
    let cocoaY = primaryHeight - (target.minY + RefusesToGrow.heightLimit)
    #expect(cocoaY == 1434)
}

@Test func aWindowThatWillNeverComplyGivesUpAfterABoundedNumberOfAttempts() {
    // A genuine minimum size, like Xcode's. There is no answer here and the
    // point is that it stops asking rather than looping.
    let minimum = CGSize(width: 600, height: 400)
    var frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    var sizeWrites = 0
    var pauses = 0
    let applier = FrameApplier(
        read: { frame },
        writePosition: { frame.origin = $0 },
        writeSize: {
            sizeWrites += 1
            frame.size = CGSize(width: max($0.width, minimum.width),
                                height: max($0.height, minimum.height))
        },
        pause: { pauses += 1 }
    )

    let result = applier.apply(CGRect(x: 0, y: 0, width: 100, height: 100))

    #expect(result.attemptsUsed == 3)
    #expect(sizeWrites == 3)
    // Three attempts, three second looks. The bound is what matters: this is a
    // window that will never comply, and it still costs 30ms and then stops.
    #expect(pauses == 3)
    #expect(result.frame?.size == minimum)
}

@Test func anUnreadableWindowStopsImmediatelyRatherThanRetrying() {
    var pauses = 0
    let applier = FrameApplier(
        read: { nil },
        writePosition: { _ in },
        writeSize: { _ in },
        pause: { pauses += 1 }
    )

    let result = applier.apply(CGRect(x: 0, y: 0, width: 10, height: 10))

    #expect(result.frame == nil)
    #expect(result.attemptsUsed == 1)
    #expect(pauses == 0)
}

@Test func aFractionOfAPointCountsAsCompliance() {
    // Accessibility positions are integral; a tiled frame need not be. Without
    // the tolerance every third-of-a-screen tiling would retry three times and
    // then be logged as a refusal.
    var frame = CGRect.zero
    let applier = FrameApplier(
        read: { frame },
        writePosition: { frame.origin = $0 },
        writeSize: { frame.size = CGSize(width: $0.width.rounded(), height: $0.height.rounded()) },
        pause: {}
    )

    let result = applier.apply(CGRect(x: 0, y: 0, width: 685.333, height: 1290))

    #expect(result.attemptsUsed == 1)
    #expect(result.frame?.width == 685)
}

@Test func theOffsetIsTheWorstOfTheFourNumbers() {
    let target = CGRect(x: 10, y: 10, width: 100, height: 100)
    #expect(FrameApplier.offset(of: target, from: target) == 0)
    // Height out by 570, everything else exact — the real Slack discrepancy.
    // Written as two positive heights: `CGRect.height` standardises a negative
    // one, so `100 - 570` would quietly have measured 470 instead.
    let asked = CGRect(x: 10, y: 10, width: 100, height: 1860)
    let got = CGRect(x: 10, y: 10, width: 100, height: 1290)
    #expect(FrameApplier.offset(of: got, from: asked) == 570)
    // Position out by more than the size is: the worst one wins.
    let moved = CGRect(x: 10 - 900, y: 10, width: 100, height: 90)
    #expect(FrameApplier.offset(of: moved, from: target) == 900)
}

@Test func aWindowStillSettlingIsGivenASecondLookBeforeBeingBlamed() {
    // Slack's logged frames drifted between attempts — -952, then -825, then
    // -857 — which is an application mid-relayout being read too early. A window
    // that arrives one read late is compliant, and must not be reported as a
    // refusal on the strength of a frame it was only passing through.
    let target = CGRect(x: 10, y: 20, width: 300, height: 400)
    var reads = 0
    var pauses = 0
    let applier = FrameApplier(
        read: {
            reads += 1
            // The first read catches it halfway; the second, after the pause,
            // catches where it landed.
            return reads == 1 ? CGRect(x: 10, y: 20, width: 150, height: 200) : target
        },
        writePosition: { _ in },
        writeSize: { _ in },
        pause: { pauses += 1 }
    )

    let result = applier.apply(target)

    #expect(result.frame == target)
    // Still one attempt: the second look is not a retry, and nothing was
    // written twice.
    #expect(result.attemptsUsed == 1)
    #expect(pauses == 1)
    #expect(reads == 2)
}
