import CoreGraphics
import Geometry
import Testing
@testable import WindowKit

/// The display the report came from, and Slack's size on it.
private let bigScreen = ScreenInfo(
    id: 2,
    frame: CGRect(x: -3360, y: 864, width: 3360, height: 1890),
    visibleFrame: CGRect(x: -3360, y: 864, width: 3360, height: 1860)
)
private let slack = CGRect(x: -3360, y: 864, width: 1028, height: 1290)

@Test func theFirstTrialAsksForTheSizeTheWindowAlreadyHas() {
    let trials = WindowProbe.trials(for: slack, on: bigScreen)

    // The control has to come first. Read the log top to bottom and a refusal
    // here reframes everything below it, so it must not be buried.
    #expect(trials.first?.frame.size == slack.size)
    #expect(trials.first?.question == "its own current size")
}

@Test func widthAndHeightAreAskedForSeparately() {
    let trials = WindowProbe.trials(for: slack, on: bigScreen)

    let widthOnly = trials.first { $0.question.contains("full usable width") }
    #expect(widthOnly?.frame.width == 3360)
    // Unchanged, which is the whole point of asking one at a time.
    #expect(widthOnly?.frame.height == 1290)

    let heightOnly = trials.first { $0.question.contains("full usable height") }
    #expect(heightOnly?.frame.height == 1860)
    #expect(heightOnly?.frame.width == 1028)
}

@Test func theHeightIsBisectedBetweenWhatItHasAndWhatItRefused() {
    let trials = WindowProbe.trials(for: slack, on: bigScreen)
    let heights = trials.filter { $0.question.hasPrefix("height ") }.map { $0.frame.height }

    // Quarter, half, three quarters of the way from 1290 to 1860.
    #expect(heights == [1432.5, 1575, 1717.5])
    // All strictly between, or they would not be bisecting anything.
    #expect(heights.allSatisfy { $0 > 1290 && $0 < 1860 })
}

@Test func aWindowThatAlreadyFillsTheDisplayIsNotAskedToGrowIntoIt() {
    // Otherwise the bisection would emit three trials asking for a height the
    // window already has, and three false passes would read as three real ones.
    let full = bigScreen.visibleFrame
    let trials = WindowProbe.trials(for: full, on: bigScreen)

    #expect(trials.filter { $0.question.hasPrefix("height ") }.isEmpty)
}

@Test func shrinkingIsAskedAboutTooBecauseItIsADifferentQuestion() {
    let trials = WindowProbe.trials(for: slack, on: bigScreen)
    let smaller = trials.first { $0.question == "half its current size" }

    #expect(smaller?.frame.size == CGSize(width: 514, height: 645))
}

@Test func everyTrialStaysWithinTheUsableArea() {
    // A trial that asks for something off-screen would be refused for a reason
    // that has nothing to do with what is being investigated.
    let usable = bigScreen.visibleFrame
    for trial in WindowProbe.trials(for: slack, on: bigScreen) {
        #expect(trial.frame.minX >= usable.minX)
        #expect(trial.frame.minY >= usable.minY)
        #expect(trial.frame.maxX <= usable.maxX)
        #expect(trial.frame.maxY <= usable.maxY)
    }
}

/// Records what it was asked and answers the way Slack answered.
private final class StubbornWindow: WindowHandle {
    let key = WindowKey(pid: 1, elementHash: 0)
    let bundleIdentifier: String? = "com.tinyspeck.slackmacgap"
    var current: CGRect
    var asked: [CGRect] = []
    /// Any height above this is ignored outright, as observed.
    let heightLimit: CGFloat

    init(_ frame: CGRect, heightLimit: CGFloat) {
        current = frame
        self.heightLimit = heightLimit
    }

    func frame() -> CGRect? { current }

    @discardableResult
    func setFrame(_ cocoaRect: CGRect) -> CGRect? {
        asked.append(cocoaRect)
        current.origin = cocoaRect.origin
        if cocoaRect.height <= heightLimit { current.size = cocoaRect.size }
        return current
    }
}

@Test func theProbePutsTheWindowBackWhereItFoundIt() {
    let window = StubbornWindow(slack, heightLimit: 1290)

    WindowProbe.run(on: window, screen: bigScreen)

    // The last thing it does, and it matters: a window left mid-bisection makes
    // the next probe's control trial a lie.
    #expect(window.asked.last == slack)
    #expect(window.current == slack)
}

@Test func theProbeAsksEveryTrialEvenAfterOneIsRefused() {
    let window = StubbornWindow(slack, heightLimit: 1290)

    WindowProbe.run(on: window, screen: bigScreen)

    let trials = WindowProbe.trials(for: slack, on: bigScreen)
    // Stopping at the first refusal would answer "is there a wall" but not
    // "where is it", and the second question is the one being asked.
    #expect(window.asked.count == trials.count + 1)
    #expect(window.asked.dropLast() == trials.map { $0.frame })
}
