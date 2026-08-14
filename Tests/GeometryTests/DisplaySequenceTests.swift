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
private let third = ScreenInfo(
    id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055)
)

@Test func nextDisplayWrapsAroundToTheFirst() {
    let all = [builtIn, external]
    #expect(neighbouringScreen(from: builtIn, in: all, direction: .next)?.id == 2)
    #expect(neighbouringScreen(from: external, in: all, direction: .next)?.id == 1)
}

@Test func previousDisplayWrapsAroundToTheLast() {
    let all = [builtIn, external]
    #expect(neighbouringScreen(from: external, in: all, direction: .previous)?.id == 1)
    #expect(neighbouringScreen(from: builtIn, in: all, direction: .previous)?.id == 2)
}

@Test func sequenceFollowsSpatialOrderNotInputOrder() {
    // `third` is physically left of `builtIn`, so spatial order is 3, 1, 2
    // even though the array is given in a different order.
    let all = [builtIn, external, third]
    #expect(neighbouringScreen(from: third, in: all, direction: .next)?.id == 1)
    #expect(neighbouringScreen(from: builtIn, in: all, direction: .next)?.id == 2)
    #expect(neighbouringScreen(from: external, in: all, direction: .next)?.id == 3)
    #expect(neighbouringScreen(from: third, in: all, direction: .previous)?.id == 2)
}

@Test func singleDisplayHasNoNeighbour() {
    #expect(neighbouringScreen(from: builtIn, in: [builtIn], direction: .next) == nil)
    #expect(neighbouringScreen(from: builtIn, in: [], direction: .next) == nil)
}

@Test func aboveAndBelowAreNotDisplayDirections() {
    // Reserved for Spaces in M4. A display move must never silently
    // reinterpret them as next/previous.
    let all = [builtIn, external]
    #expect(neighbouringScreen(from: builtIn, in: all, direction: .above) == nil)
    #expect(neighbouringScreen(from: builtIn, in: all, direction: .below) == nil)
}

@Test func unknownCurrentDisplayHasNoNeighbour() {
    #expect(neighbouringScreen(from: third, in: [builtIn, external], direction: .next) == nil)
}
