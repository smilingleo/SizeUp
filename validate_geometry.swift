#!/usr/bin/swift
import Foundation
import CoreGraphics

struct Gaps: Equatable {
    var inner: CGFloat
    var outer: CGFloat
    init(inner: CGFloat = 0, outer: CGFloat = 0) {
        self.inner = inner
        self.outer = outer
    }
    static let zero = Gaps(inner: 0, outer: 0)
}

struct ScreenInfo: Equatable {
    let id: Int
    let frame: CGRect
    let visibleFrame: CGRect
}

enum Edge: CaseIterable {
    case left, right, top, bottom
}

enum Corner: CaseIterable {
    case upperLeft, upperRight, lowerLeft, lowerRight
}

enum Direction {
    case next, previous, above, below
}

enum Action: Equatable {
    case half(Edge)
    case quarter(Corner)
    case center
    case fullScreen
    case snapBack
    case display(Direction)
    case space(Direction)
}

func targetFrame(
    for action: Action,
    on screen: ScreenInfo,
    gaps: Gaps = .zero,
    current: CGRect? = nil,
    fraction: CGFloat = 0.5
) -> CGRect? {
    let usable = screen.visibleFrame.insetBy(dx: gaps.outer, dy: gaps.outer)
    guard usable.width > 0, usable.height > 0 else { return nil }

    switch action {
    case .fullScreen:
        return usable

    case .center:
        guard let current else { return nil }
        let size = CGSize(
            width: min(current.width, usable.width),
            height: min(current.height, usable.height)
        )
        return CGRect(
            x: (usable.midX - size.width / 2).rounded(.down),
            y: (usable.midY - size.height / 2).rounded(.down),
            width: size.width,
            height: size.height
        )

    case .half(let edge):
        switch edge {
        case .left:
            let w = leadingExtent(usable.width, fraction, gaps.inner)
            return CGRect(x: usable.minX, y: usable.minY, width: w, height: usable.height)
        case .right:
            let w = trailingExtent(usable.width, fraction, gaps.inner)
            return CGRect(x: usable.maxX - w, y: usable.minY, width: w, height: usable.height)
        case .bottom:
            let h = leadingExtent(usable.height, fraction, gaps.inner)
            return CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: h)
        case .top:
            let h = trailingExtent(usable.height, fraction, gaps.inner)
            return CGRect(x: usable.minX, y: usable.maxY - h, width: usable.width, height: h)
        }

    case .quarter(let corner):
        let leftW = leadingExtent(usable.width, 0.5, gaps.inner)
        let rightW = trailingExtent(usable.width, 0.5, gaps.inner)
        let bottomH = leadingExtent(usable.height, 0.5, gaps.inner)
        let topH = trailingExtent(usable.height, 0.5, gaps.inner)
        switch corner {
        case .upperLeft:
            return CGRect(x: usable.minX, y: usable.maxY - topH, width: leftW, height: topH)
        case .upperRight:
            return CGRect(x: usable.maxX - rightW, y: usable.maxY - topH, width: rightW, height: topH)
        case .lowerLeft:
            return CGRect(x: usable.minX, y: usable.minY, width: leftW, height: bottomH)
        case .lowerRight:
            return CGRect(x: usable.maxX - rightW, y: usable.minY, width: rightW, height: bottomH)
        }

    case .snapBack, .display, .space:
        return nil
    }
}

private func boundaryCount(_ fraction: CGFloat) -> CGFloat {
    guard fraction > 0 else { return 0 }
    return max(0, (1 / fraction).rounded(.up) - 1)
}

private func leadingExtent(_ total: CGFloat, _ fraction: CGFloat, _ inner: CGFloat) -> CGFloat {
    let available = total - boundaryCount(fraction) * inner
    return max(0, (available * fraction).rounded(.down))
}

private func trailingExtent(_ total: CGFloat, _ fraction: CGFloat, _ inner: CGFloat) -> CGFloat {
    let available = total - boundaryCount(fraction) * inner
    let complement = (available * (1 - fraction)).rounded(.down)
    return max(0, available - complement)
}

let builtIn = ScreenInfo(
    id: 0,
    frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)

var passed = 0
var failed = 0

func test(_ name: String, _ fn: () -> Bool) {
    if fn() {
        print("✓ \(name)")
        passed += 1
    } else {
        print("✗ \(name)")
        failed += 1
    }
}

test("leftHalfFillsLeftOfVisibleFrame") {
    targetFrame(for: .half(.left), on: builtIn) == CGRect(x: 0, y: 0, width: 1680, height: 1860)
}

test("rightHalfFillsRightOfVisibleFrame") {
    targetFrame(for: .half(.right), on: builtIn) == CGRect(x: 1680, y: 0, width: 1680, height: 1860)
}

test("topHalfUsesHighYAndAvoidsMenuBar") {
    let r = targetFrame(for: .half(.top), on: builtIn)
    return r == CGRect(x: 0, y: 930, width: 3360, height: 930) && (r?.maxY ?? 0) <= builtIn.visibleFrame.maxY
}

test("bottomHalfUsesLowY") {
    targetFrame(for: .half(.bottom), on: builtIn) == CGRect(x: 0, y: 0, width: 3360, height: 930)
}

test("leftHalfRespectsDockOnLeft") {
    let dockLeft = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
        visibleFrame: CGRect(x: 80, y: 0, width: 3280, height: 1860)
    )
    return targetFrame(for: .half(.left), on: dockLeft) == CGRect(x: 80, y: 0, width: 1640, height: 1860)
}

test("oddWidthHalvesTileExactly") {
    let odd = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 1401, height: 901),
        visibleFrame: CGRect(x: 0, y: 0, width: 1401, height: 901)
    )
    let left = targetFrame(for: .half(.left), on: odd)!
    let right = targetFrame(for: .half(.right), on: odd)!
    return left.width == 700 && right.width == 701 && left.maxX == right.minX && left.width + right.width == 1401
}

test("oddHeightHalvesTileExactly") {
    let odd = ScreenInfo(
        id: 0,
        frame: CGRect(x: 0, y: 0, width: 1401, height: 901),
        visibleFrame: CGRect(x: 0, y: 0, width: 1401, height: 901)
    )
    let bottom = targetFrame(for: .half(.bottom), on: odd)!
    let top = targetFrame(for: .half(.top), on: odd)!
    return bottom.height == 450 && top.height == 451 && bottom.maxY == top.minY
}

test("gapsInsetEdgesAndSplitSharedBoundary") {
    let g = Gaps(inner: 10, outer: 20)
    let left = targetFrame(for: .half(.left), on: builtIn, gaps: g)!
    let right = targetFrame(for: .half(.right), on: builtIn, gaps: g)!
    return left.minX == 20 && right.maxX == 3340 && left.minY == 20 && left.height == 1820 && (right.minX - left.maxX) == 10
}

test("twoThirdsAndOneThirdTileExactly") {
    let big = targetFrame(for: .half(.left), on: builtIn, fraction: 2.0 / 3.0)!
    let small = targetFrame(for: .half(.right), on: builtIn, fraction: 1.0 / 3.0)!
    return big.maxX == small.minX && big.width + small.width == 3360
}

print("\n\(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
