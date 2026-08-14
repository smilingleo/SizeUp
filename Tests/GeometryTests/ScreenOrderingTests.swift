import CoreGraphics
import Testing
@testable import Geometry

private let builtIn = ScreenInfo(
    id: 1, frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)
private let external = ScreenInfo(
    id: 2, frame: CGRect(x: 3360, y: -838, width: 2056, height: 1329),
    visibleFrame: CGRect(x: 3360, y: -838, width: 2056, height: 1291)
)

@Test func ordersDisplaysLeftToRightRegardlessOfInputOrder() {
    #expect(spatiallyOrdered([external, builtIn]).map(\.id) == [1, 2])
    #expect(spatiallyOrdered([builtIn, external]).map(\.id) == [1, 2])
}

@Test func ordersVerticallyStackedDisplaysBottomToTop() {
    // Same minX, so minY breaks the tie. The lower display comes first.
    let lower = ScreenInfo(
        id: 10, frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    )
    let upper = ScreenInfo(
        id: 11, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
    )
    #expect(spatiallyOrdered([upper, lower]).map(\.id) == [10, 11])
}

@Test func orderingIsStableForASingleDisplay() {
    #expect(spatiallyOrdered([builtIn]).map(\.id) == [1])
    #expect(spatiallyOrdered([]).isEmpty)
}
