import Annotation
import CoreGraphics
import Testing
@testable import App

// The compositor is what makes the editor real: if it drops the annotations,
// everything the user drew is silently thrown away on copy.

/// A white screenshot, so any drawn ink is unambiguous.
private func white(_ w: Int, _ h: Int) -> CGImage {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage()!
}

/// Read a pixel, y=0 at the top.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { raw in
        let c = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let i = (y * image.width + x) * 4
    return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
}

private let red = AnnotationColor(r: 1, g: 0, b: 0)

@Test func aCropWithNoAnnotationsIsTheCropItself() {
    let image = white(200, 100)
    let out = Compositor.flatten(image, selection: CGRect(x: 20, y: 10, width: 100, height: 50),
                                 scale: 1, annotations: [])
    #expect(out?.width == 100)
    #expect(out?.height == 50)
}

@Test func annotationsSurviveTheCopy() {
    // The regression that would make the whole editor pointless.
    let image = white(200, 100)
    let annotation = Annotation(
        kind: .highlight(origin: CGPoint(x: 40, y: 30), size: CGSize(width: 40, height: 20)),
        color: red)
    let out = Compositor.flatten(image, selection: CGRect(x: 20, y: 10, width: 100, height: 50),
                                 scale: 1, annotations: [annotation])!
    // The highlight sits at (40,30) on the display, so (20,20) inside the crop.
    let (r, g, _) = pixel(out, 40, 30)
    #expect(r > 200 && g < 200, "the annotation did not make it into the output")
}

@Test func annotationsLandWhereTheUserSawThem() {
    // The transform has to undo the region's origin. Getting it wrong shifts
    // every shape by the region offset — which looks fine on a full-screen
    // capture and wrong on every other one.
    let image = white(400, 300)
    let selection = CGRect(x: 100, y: 50, width: 200, height: 150)
    // A rect exactly filling the region's top-left quadrant.
    let annotation = Annotation(
        kind: .highlight(origin: CGPoint(x: 100, y: 50), size: CGSize(width: 100, height: 75)),
        color: red)
    let out = Compositor.flatten(image, selection: selection, scale: 1,
                                 annotations: [annotation])!
    #expect(out.width == 200 && out.height == 150)

    func isRed(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = pixel(out, x, y)
        return r > 180 && g < 200 && b < 200
    }
    #expect(isRed(50, 37), "the top-left quadrant should be covered")
    #expect(!isRed(150, 112), "the bottom-right quadrant should be untouched")
}

@Test func annotationsScaleWithARetinaDisplay() {
    // Annotations are in points; the output is in pixels. On a 2x display a
    // shape must come out twice as large, in the right place.
    let image = white(400, 200)          // a 200x100pt display at 2x
    let selection = CGRect(x: 0, y: 0, width: 100, height: 50)
    let annotation = Annotation(
        kind: .highlight(origin: CGPoint(x: 0, y: 0), size: CGSize(width: 50, height: 25)),
        color: red)
    let out = Compositor.flatten(image, selection: selection, scale: 2,
                                 annotations: [annotation])!
    #expect(out.width == 200 && out.height == 100, "the output is in pixels")

    func isRed(_ x: Int, _ y: Int) -> Bool {
        let (r, g, b) = pixel(out, x, y)
        return r > 180 && g < 200 && b < 200
    }
    // The 50x25pt highlight covers the top-left 100x50 px of the output.
    #expect(isRed(50, 25), "inside the scaled shape")
    #expect(!isRed(150, 75), "outside the scaled shape")
}

@Test func aBlurInTheOutputSamplesTheOriginalPixels() {
    // The blur has to mosaic the screenshot, not the half-drawn canvas, or a
    // shape drawn over it would get smeared into the mosaic.
    let w = 200, h = 100
    let source: CGImage = {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for i in 0..<(w / 2) { c.fill(CGRect(x: i * 2, y: 0, width: 1, height: h)) }
        return c.makeImage()!
    }()
    let out = Compositor.flatten(
        source, selection: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 1,
        annotations: [Annotation(kind: .blur(origin: CGPoint(x: 40, y: 20),
                                             size: CGSize(width: 80, height: 40)))])!

    func transitions(_ y: Int, _ x0: Int, _ x1: Int) -> Int {
        var n = 0
        for x in (x0 + 1)..<x1 where (pixel(out, x, y).0 < 128) != (pixel(out, x - 1, y).0 < 128) {
            n += 1
        }
        return n
    }
    let inside = transitions(40, 45, 115)
    let outside = transitions(5, 45, 115)
    #expect(outside > 30)
    #expect(inside < outside / 2, "the blur did not obscure the stripes in the output")
}

@Test func anEmptySelectionProducesNothingRatherThanCrashing() {
    let image = white(100, 100)
    #expect(Compositor.flatten(image, selection: .zero, scale: 1, annotations: []) == nil)
}
