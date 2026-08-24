import CoreGraphics
import Testing
@testable import Capture

// `CropImage` is the point→pixel math with decisions in it, so it gets real
// tests with a synthetic image rather than riding the manual checklist.

private func solidImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace, bitmapInfo: info
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func aFullSelectionCropsToTheWholeImage() {
    let image = solidImage(width: 100, height: 50)
    // Selection in points; scale 2 → the full 100×50 image.
    let crop = CropImage.crop(image, selection: CGRect(x: 0, y: 0, width: 50, height: 25), scale: 2)
    #expect(crop != nil)
    #expect(crop?.width == 100)
    #expect(crop?.height == 50)
}

@Test func aHalfSelectionCropsToHalfThePixels() {
    let image = solidImage(width: 100, height: 50)
    let crop = CropImage.crop(image, selection: CGRect(x: 0, y: 0, width: 25, height: 25), scale: 2)
    #expect(crop?.width == 50)
    #expect(crop?.height == 50)
}

@Test func anOffsetSelectionCropsAtTheRightPixels() {
    let image = solidImage(width: 100, height: 100)
    // Points (10, 5) at scale 2 → pixels (20, 10), 40×20 pixels.
    let crop = CropImage.crop(image, selection: CGRect(x: 10, y: 5, width: 20, height: 10), scale: 2)
    #expect(crop?.width == 40)
    #expect(crop?.height == 20)
}

@Test func aNonIntegerScaleStillMapsByMultiplication() {
    let image = solidImage(width: 100, height: 100)
    // A 2.5× backing scale (the 3x iPad-style / fractional Retina case):
    // 20 points → 50 pixels.
    let crop = CropImage.crop(image, selection: CGRect(x: 0, y: 0, width: 20, height: 10), scale: 2.5)
    #expect(crop?.width == 50)
    #expect(crop?.height == 25)
}

@Test func aZeroOrNegativeSelectionCropsToNothing() {
    let image = solidImage(width: 100, height: 100)
    #expect(CropImage.crop(image, selection: CGRect(x: 0, y: 0, width: 0, height: 0), scale: 2) == nil)
    #expect(CropImage.crop(image, selection: CGRect(x: 0, y: 0, width: -10, height: -10), scale: 2) == nil)
}

@Test func aSelectionOutsideTheImageCropsToNothing() {
    let image = solidImage(width: 100, height: 100)
    // Starts past the right edge: `cropping(to:)` returns nil.
    let crop = CropImage.crop(image, selection: CGRect(x: 200, y: 0, width: 10, height: 10), scale: 2)
    #expect(crop == nil)
}

@Test func normalizedFlipsANegativeOriginSize() {
    let rect = CropImage.normalized(CGPoint(x: 100, y: 100), CGSize(width: -40, height: -20))
    #expect(rect == CGRect(x: 60, y: 80, width: 40, height: 20))
}
