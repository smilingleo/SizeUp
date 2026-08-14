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

@Test func leftHalfMapsToLeftHalfOfTheDestination() {
    let mapped = proportionalFrame(
        CGRect(x: 0, y: 0, width: 1680, height: 1860), from: builtIn, to: external
    )
    #expect(mapped == CGRect(x: 3360, y: -838, width: 1028, height: 1291))
}

@Test func fullVisibleFrameMapsToFullVisibleFrameBothWays() {
    let toExternal = proportionalFrame(
        CGRect(x: 0, y: 0, width: 3360, height: 1860), from: builtIn, to: external
    )
    #expect(toExternal == CGRect(x: 3360, y: -838, width: 2056, height: 1291))

    // The reverse direction crosses from a negative-Y origin back to zero.
    let toBuiltIn = proportionalFrame(
        CGRect(x: 3360, y: -838, width: 2056, height: 1291), from: external, to: builtIn
    )
    #expect(toBuiltIn == CGRect(x: 0, y: 0, width: 3360, height: 1860))
}

@Test func arbitraryWindowKeepsItsRelativePositionAndSize() {
    let mapped = proportionalFrame(
        CGRect(x: 1280, y: 630, width: 800, height: 600), from: builtIn, to: external
    )
    #expect(mapped == CGRect(x: 4143, y: -401, width: 489, height: 416))
}

@Test func windowAtTheFarCornerStaysInsideTheDestination() {
    let mapped = proportionalFrame(
        CGRect(x: 3260, y: 1760, width: 100, height: 100), from: builtIn, to: external
    )
    #expect(mapped == CGRect(x: 5354, y: 383, width: 61, height: 69))
    // The point of the test: it must not spill past the destination edges.
    #expect(mapped.maxX <= external.visibleFrame.maxX)
    #expect(mapped.maxY <= external.visibleFrame.maxY)
}

@Test func oversizedWindowIsClampedToTheDestination() {
    // A window larger than its own source display must still fit afterwards.
    let mapped = proportionalFrame(
        CGRect(x: 0, y: 0, width: 6000, height: 4000), from: builtIn, to: external
    )
    #expect(mapped.width == 2056)
    #expect(mapped.height == 1291)
    #expect(external.visibleFrame.contains(mapped))
}

@Test func degenerateSourceReturnsTheFrameUnchanged() {
    let broken = ScreenInfo(id: 9, frame: .zero, visibleFrame: .zero)
    let original = CGRect(x: 10, y: 20, width: 30, height: 40)
    #expect(proportionalFrame(original, from: broken, to: external) == original)
}
