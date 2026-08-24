import CoreGraphics
import Testing
@testable import WindowKit

/// Records the order it was written in, and can be told which order it likes.
private final class OrderSensitiveWindow: RawFrameWriting {
    var frame: CGRect
    /// Whether a position write re-asserts the size the window already had,
    /// which is the suspicion the probe exists to test.
    let positionReassertsSize: Bool
    var log: [String] = []

    init(_ frame: CGRect, positionReassertsSize: Bool) {
        self.frame = frame
        self.positionReassertsSize = positionReassertsSize
    }

    func readAXFrame() -> CGRect? { frame }

    func writeAXPosition(_ position: CGPoint) {
        log.append("position")
        let held = frame.size
        frame.origin = position
        if positionReassertsSize { frame.size = held }
    }

    func writeAXSize(_ size: CGSize) {
        log.append("size")
        frame.size = size
    }
}

private let start = CGRect(x: -3360, y: -1395, width: 1028, height: 1539)
private let target = CGRect(x: -3360, y: -1395, width: 1028, height: 1860)

private func run(_ window: OrderSensitiveWindow) -> [String] {
    var lines: [String] = []
    WriteOrderProbe.run(on: window, target: target, original: start,
                        pause: {}, describe: { lines.append($0) })
    return lines
}

@Test func theFirstPlanIsWhatTheApplicationAlreadyDoes() {
    // Every later line is read as a comparison against this one, so it has to be
    // the control and it has to be first.
    #expect(WriteOrderProbe.plans.first?.steps == [.position, .size, .position])
    #expect(WriteOrderProbe.plans.first?.name.contains("what ClipShot does") ?? false)
}

@Test func onePlanWritesTheSizeWithNoPositionWriteAfterIt() {
    // The direct test of the suspicion. Without it the probe cannot distinguish
    // "the order is wrong" from "the window is stubborn".
    let plans = WriteOrderProbe.plans.map(\.steps)
    #expect(plans.contains([.position, .size]))
    #expect(plans.contains([.size]))
}

@Test func everyPlanWritesTheSizeAtLeastOnce() {
    // A plan that never asks for the size cannot answer anything about it, and
    // would sit in the log looking like evidence.
    for plan in WriteOrderProbe.plans {
        #expect(plan.steps.contains(.size))
    }
}

@Test func planNamesAreDistinctSoTheLogIsReadable() {
    let names = Set(WriteOrderProbe.plans.map(\.name))
    #expect(names.count == WriteOrderProbe.plans.count)
}

@Test func aWindowWhosePositionWriteReassertsItsSizeIsCaughtByTheRightPlan() {
    // The whole point. If this is what Slack is doing, exactly the plans ending
    // in a position write should fail and the rest should succeed — and that
    // pattern in the log is the fix, spelled out.
    let window = OrderSensitiveWindow(start, positionReassertsSize: true)

    let lines = run(window)

    let took = zip(WriteOrderProbe.plans, lines).filter { $0.1.contains("TOOK THE HEIGHT") }
    let names = took.map(\.0.name)
    #expect(names.contains("position, size"))
    #expect(names.contains("size alone"))
    #expect(names.contains("position, pause, size"))
    // And the shipping order is precisely the one that fails.
    let control = lines.first { $0.contains("what ClipShot does") }
    #expect(control?.contains("height unchanged at 1539") ?? false)
}

@Test func aWindowThatSimplyIgnoresHeightFailsEveryPlan() {
    // The other outcome, and the probe has to be able to report it: if no order
    // works then the height is not ours to change, and the answer is a paragraph
    // in the README rather than more code.
    // Height writes ignored entirely, width honoured, as measured.
    let window = HeightProofWindow(start)

    var lines: [String] = []
    WriteOrderProbe.run(on: window, target: target, original: start,
                        pause: {}, describe: { lines.append($0) })

    #expect(lines.count == WriteOrderProbe.plans.count)
    #expect(lines.allSatisfy { $0.contains("height unchanged at 1539") })
}

/// Honours width, ignores height. Slack, as measured.
private final class HeightProofWindow: RawFrameWriting {
    private var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }

    func readAXFrame() -> CGRect? { frame }
    func writeAXPosition(_ position: CGPoint) { frame.origin = position }
    func writeAXSize(_ size: CGSize) {
        frame.size = CGSize(width: size.width, height: frame.height)
    }
}

@Test func eachPlanStartsFromTheOriginalFrame() {
    // Without restoring in between, plan two inherits whatever plan one left,
    // and a plan can then pass because an earlier one did the work.
    let window = OrderSensitiveWindow(start, positionReassertsSize: false)

    _ = run(window)

    // Restored once before each plan and once at the end.
    #expect(window.log.filter { $0 == "size" }.count
        >= WriteOrderProbe.plans.count + 1)
    #expect(window.frame == start)
}

@Test func theWindowIsLeftAsItWasFound() {
    let window = OrderSensitiveWindow(start, positionReassertsSize: true)

    _ = run(window)

    #expect(window.frame == start)
}
