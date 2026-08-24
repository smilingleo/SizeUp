import CoreGraphics
import Testing
@testable import WindowKit

/// A window that does as it is told.
private final class Cooperative {
    var frame: CGRect
    var positionWrites = 0
    var sizeWrites = 0

    init(_ frame: CGRect) { self.frame = frame }

    func applier() -> FrameApplier {
        FrameApplier(
            read: { self.frame },
            writePosition: { self.positionWrites += 1; self.frame.origin = $0 },
            writeSize: { self.sizeWrites += 1; self.frame.size = $0 }
        )
    }
}

@Test func theWindowIsWrittenToExactlyThreeTimesAndReadOnce() {
    // The regression test for a fix that made things worse.
    //
    // Chasing a report that Slack would not resize, this type briefly grew a
    // three-attempt retry and a corrective position write. The result was that
    // Slack stopped resizing on the display where it had always worked — extra
    // writes are not free, and a window that complies is the case that must not
    // be put at risk for one that never complies either way.
    //
    // So the count is pinned. Position, size, position, one read: no more, and
    // in that order.
    let window = Cooperative(CGRect(x: 0, y: 0, width: 100, height: 100))
    let target = CGRect(x: 10, y: 20, width: 300, height: 400)

    let achieved = window.applier().apply(target)

    #expect(achieved == target)
    #expect(window.positionWrites == 2)
    #expect(window.sizeWrites == 1)
}

@Test func theTrailingPositionWriteSurvivesAWindowThatClampsItsSize() {
    // Why there are two position writes and not one. An application enforcing a
    // minimum size leaves the window where the clamp put it, not where it was
    // asked to go, so the position has to be re-stated after the size.
    let minimum = CGSize(width: 600, height: 400)
    var frame = CGRect(x: 0, y: 0, width: 900, height: 700)
    var order: [String] = []
    let applier = FrameApplier(
        read: { frame },
        writePosition: {
            order.append("position")
            frame.origin = $0
        },
        writeSize: {
            order.append("size")
            frame = CGRect(
                // A clamp that also shifts the window, as a real one does.
                x: frame.minX + 40, y: frame.minY + 40,
                width: max($0.width, minimum.width), height: max($0.height, minimum.height)
            )
        }
    )

    let achieved = applier.apply(CGRect(x: 500, y: 500, width: 100, height: 100))

    #expect(order == ["position", "size", "position"])
    // The size is the clamped one, but the origin is the requested one.
    #expect(achieved == CGRect(x: 500, y: 500, width: 600, height: 400))
}

@Test func everyWriteHappensInsideTheSuppressionAndTheReadHappensOutsideIt() {
    // The shape the measurement demands. An application with
    // `AXEnhancedUserInterface` on animates a frame change, and the size write
    // is then lost to the animation the position write started — so the mode has
    // to be off before the FIRST write, not restored between them, and not
    // turned off only after a refusal (measured: that fixes nothing).
    //
    // The read is deliberately outside, so what is reported is what the window
    // settled on with its own mode restored.
    var order: [String] = []
    var frame = CGRect.zero
    let applier = FrameApplier(
        read: { order.append("read"); return frame },
        writePosition: { order.append("position"); frame.origin = $0 },
        writeSize: { order.append("size"); frame.size = $0 },
        suppressingEnhancedUserInterface: { writes in
            order.append("suppress")
            writes()
            order.append("restore")
        }
    )

    _ = applier.apply(CGRect(x: 1, y: 2, width: 3, height: 4))

    #expect(order == ["suppress", "position", "size", "position", "restore", "read"])
}

@Test func aWindowIsAppliedExactlyOnceEvenWhenItRefusesTheSize() {
    // The suppression must not have smuggled a retry back in. A refusal is
    // reported, not chased: that is the whole lesson of the reverted fix, and
    // the reason the count is pinned in two tests rather than one.
    var writes = 0
    var suppressions = 0
    let stuck = CGRect(x: 0, y: 0, width: 685, height: 1290)
    let applier = FrameApplier(
        read: { stuck },
        writePosition: { _ in writes += 1 },
        writeSize: { _ in writes += 1 },
        suppressingEnhancedUserInterface: { body in
            suppressions += 1
            body()
        }
    )

    let achieved = applier.apply(CGRect(x: 1028, y: 0, width: 1028, height: 1290))

    #expect(achieved == stuck)
    #expect(writes == 3)
    #expect(suppressions == 1)
}

@Test func aCallerThatCannotSuppressAnythingStillGetsThePlainSequence() {
    // The default. Nothing in `Geometry` or the tests has an application to ask,
    // and a missing hook must mean "write normally", never "do not write".
    let window = Cooperative(CGRect(x: 0, y: 0, width: 100, height: 100))
    let target = CGRect(x: 10, y: 20, width: 300, height: 400)

    #expect(window.applier().apply(target) == target)
}

@Test func aFractionOfAPointCountsAsCompliance() throws {
    // Accessibility positions are integral; a tiled frame need not be. Without
    // the tolerance every third-of-a-screen tiling would be logged as a refusal.
    var frame = CGRect.zero
    let applier = FrameApplier(
        read: { frame },
        writePosition: { frame.origin = $0 },
        writeSize: { frame.size = CGSize(width: $0.width.rounded(), height: $0.height.rounded()) }
    )
    let target = CGRect(x: 0, y: 0, width: 685.333, height: 1290)

    let achieved = applier.apply(target)

    #expect(achieved?.width == 685)
    #expect(applier.accepted(try #require(achieved), as: target))
}

@Test func aRealRefusalIsNotWavedThroughByTheTolerance() {
    // The other side of the tolerance: 570pt out is the measured Slack
    // discrepancy and must not round to compliance.
    let applier = FrameApplier(read: { nil }, writePosition: { _ in }, writeSize: { _ in })
    let asked = CGRect(x: 0, y: 0, width: 1028, height: 1860)
    let got = CGRect(x: 0, y: 0, width: 1028, height: 1290)

    #expect(!applier.accepted(got, as: asked))
}

@Test func anUnreadableWindowReportsNothingRatherThanGuessing() {
    let applier = FrameApplier(read: { nil }, writePosition: { _ in }, writeSize: { _ in })

    #expect(applier.apply(CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
}

@Test func theOffsetIsTheWorstOfTheFourNumbers() {
    let target = CGRect(x: 10, y: 10, width: 100, height: 100)
    #expect(FrameApplier.offset(of: target, from: target) == 0)

    // Height out by 570, everything else exact — the measured Slack discrepancy.
    // Written as two positive heights: `CGRect.height` standardises a negative
    // one, so `100 - 570` would quietly have measured something else.
    let asked = CGRect(x: 10, y: 10, width: 100, height: 1860)
    let got = CGRect(x: 10, y: 10, width: 100, height: 1290)
    #expect(FrameApplier.offset(of: got, from: asked) == 570)

    // Position out by more than the size is: the worst one wins.
    let moved = CGRect(x: 10 - 900, y: 10, width: 100, height: 90)
    #expect(FrameApplier.offset(of: moved, from: target) == 900)
}
