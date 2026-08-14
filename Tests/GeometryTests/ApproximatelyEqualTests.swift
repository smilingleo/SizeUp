import Testing
import CoreGraphics
@testable import Geometry

private let base = CGRect(x: 100, y: 100, width: 800, height: 600)

@Test func identicalFramesAreApproximatelyEqual() {
    #expect(approximatelyEqual(base, base))
}

@Test func onePointDriftWithinDefaultToleranceIsEqual() {
    let drifted = base.offsetBy(dx: 1, dy: -1)
    #expect(approximatelyEqual(base, drifted))
}

@Test func threePointDriftIsNotEqual() {
    let drifted = base.offsetBy(dx: 3, dy: 0)
    #expect(!approximatelyEqual(base, drifted))
}

@Test func sizeDifferenceBeyondToleranceIsNotEqual() {
    let resized = CGRect(x: base.minX, y: base.minY, width: base.width + 3, height: base.height)
    #expect(!approximatelyEqual(base, resized))
}

@Test func customToleranceIsHonoured() {
    let drifted = base.offsetBy(dx: 3, dy: 0)
    #expect(approximatelyEqual(base, drifted, tolerance: 5))
}
