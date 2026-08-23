import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Annotation

/// A top-left-origin bitmap, which is the renderer's documented contract, plus
/// pixel access. Rendering to a real surface is the only way to test a
/// renderer: every interesting bug here (a mirrored image, upside-down glyphs,
/// a blur that quietly does nothing) is invisible to a test that only inspects
/// the model.
private struct Canvas {
    let width: Int
    let height: Int
    let context: CGContext
    private var pixels: [UInt8]

    init(_ width: Int = 200, _ height: Int = 120, background: CGFloat = 1) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: background, green: background, blue: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to top-left origin, as the overlay's flipped NSView does.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    /// Snapshot the pixels, indexed with y=0 at the top.
    mutating func read() {
        let image = context.makeImage()!
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    /// Count pixels that differ from white — i.e. how much was drawn.
    func ink(in rect: CGRect) -> Int {
        var n = 0
        for y in Int(rect.minY)..<Int(rect.maxY) where y >= 0 && y < height {
            for x in Int(rect.minX)..<Int(rect.maxX) where x >= 0 && x < width {
                let (r, g, b) = rgb(x, y)
                if r < 250 || g < 250 || b < 250 { n += 1 }
            }
        }
        return n
    }

    var allInk: Int { ink(in: CGRect(x: 0, y: 0, width: width, height: height)) }
}

private let red = AnnotationColor(r: 1, g: 0, b: 0)

// MARK: Every kind draws, and draws where it says it does

@Test func everyKindPutsInkInsideItsBounds() {
    // A shape whose bounding rect does not contain its own ink is a shape the
    // user cannot select or drag, because hit-testing trusts the bounds.
    let kinds: [(String, Annotation.Kind)] = [
        ("arrow", .arrow(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 150, y: 90))),
        ("rect", .rect(origin: CGPoint(x: 30, y: 25), size: CGSize(width: 120, height: 60))),
        ("ellipse", .ellipse(origin: CGPoint(x: 30, y: 25), size: CGSize(width: 120, height: 60))),
        ("pencil", .pencil(points: [CGPoint(x: 30, y: 30), CGPoint(x: 90, y: 80), CGPoint(x: 150, y: 40)])),
        ("text", .text(position: CGPoint(x: 30, y: 40), text: "Hello")),
        ("callout", .callout(origin: CGPoint(x: 40, y: 20), size: CGSize(width: 120, height: 50),
                             pointer: CGPoint(x: 20, y: 100), text: "Hi")),
        ("highlight", .highlight(origin: CGPoint(x: 30, y: 40), size: CGSize(width: 120, height: 30))),
        ("step", .step(center: CGPoint(x: 100, y: 60), radius: 14)),
    ]
    for (name, kind) in kinds {
        var canvas = Canvas()
        let annotation = Annotation(kind: kind, color: red, width: 3)
        AnnotationRenderer.draw(annotation, in: canvas.context)
        canvas.read()

        #expect(canvas.allInk > 0, "\(name) drew nothing at all")
        // All the ink must sit inside the bounds, padded for stroke width,
        // shadow and the text backdrop.
        let bounds = annotation.boundingRect().insetBy(dx: -12, dy: -12)
        #expect(canvas.ink(in: bounds) == canvas.allInk, "\(name) drew outside its bounds")
    }
}

@Test func textIsUprightNotMirrored() {
    // "F" is top-heavy: two bars up top, a bare stem below. If CoreText draws
    // into the flipped context without the baseline flip, the glyph inverts and
    // the weight moves to the bottom. Nothing in the model can catch this.
    var canvas = Canvas(200, 60)
    AnnotationRenderer.draw(
        Annotation(kind: .text(position: CGPoint(x: 10, y: 10), text: "FFFFF"),
                   color: AnnotationColor(r: 0, g: 0, b: 0), width: 3),
        in: canvas.context)
    canvas.read()

    // Measure ink above and below the middle of the glyph body. The backdrop
    // plate is symmetric, so it cannot bias the comparison.
    let size = "FFFFF".measure(size: AnnotationStyle.defaultFontSize)
    let body = CGRect(x: 10, y: 10, width: size.width, height: size.height)
    let top = canvas.ink(in: CGRect(x: body.minX, y: body.minY,
                                    width: body.width, height: body.height / 2))
    let bottom = canvas.ink(in: CGRect(x: body.minX, y: body.midY,
                                       width: body.width, height: body.height / 2))
    #expect(top > bottom, "text is upside down: an F is top-heavy (top \(top), bottom \(bottom))")
}

@Test func stepNumbersComeFromRenderOrder() {
    // The model stores no number, so two steps must be distinguishable only by
    // their position in the list. This is what lets a delete renumber the rest
    // without rewriting a single stored shape.
    func render(_ count: Int) -> [Int] {
        var inks: [Int] = []
        var canvas = Canvas(300, 60)
        let steps = (0..<count).map {
            Annotation(kind: .step(center: CGPoint(x: 30 + CGFloat($0) * 40, y: 30), radius: 14),
                       color: red, width: 3)
        }
        AnnotationRenderer.draw(steps, in: canvas.context)
        canvas.read()
        for i in 0..<count {
            inks.append(canvas.ink(in: CGRect(x: 16 + CGFloat(i) * 40, y: 16, width: 28, height: 28)))
        }
        return inks
    }
    let two = render(2)
    #expect(two.count == 2)
    #expect(two.allSatisfy { $0 > 0 })
    // "1" and "2" are different glyphs, so their ink differs.
    #expect(two[0] != two[1], "both steps rendered the same number")
}

@Test func blurObscuresFineDetail() {
    // A blur that draws nothing, or draws the source untouched, still looks
    // plausible on a coarse background. Fine stripes are the honest test: after
    // a mosaic the row must have fewer transitions than it started with.
    let w = 120, h = 60
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

    var canvas = Canvas(w, h)
    canvas.context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
    AnnotationRenderer.draw(
        Annotation(kind: .blur(origin: CGPoint(x: 20, y: 10), size: CGSize(width: 80, height: 40))),
        in: canvas.context, blurSource: source, blurScale: 1)
    canvas.read()

    func transitions(_ y: Int, _ x0: Int, _ x1: Int) -> Int {
        var n = 0
        for x in (x0 + 1)..<x1 where (canvas.rgb(x, y).0 < 128) != (canvas.rgb(x - 1, y).0 < 128) {
            n += 1
        }
        return n
    }
    let inside = transitions(30, 25, 95)
    let outside = transitions(5, 25, 95)
    #expect(outside > 30, "the source stripes should be intact outside the blur")
    #expect(inside < outside / 2, "blur did not obscure: \(inside) vs \(outside) transitions")
}

@Test func blurWithoutASourceStillHides() {
    // Falling back to nothing would leak exactly what the user asked to hide,
    // so an absent source must still paint something opaque.
    var canvas = Canvas(80, 60)
    AnnotationRenderer.draw(
        Annotation(kind: .blur(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 60, height: 40))),
        in: canvas.context, blurSource: nil)
    canvas.read()
    #expect(canvas.ink(in: CGRect(x: 12, y: 12, width: 56, height: 36)) > 1900)
}

@Test func degenerateShapesDrawNothingAndDoNotCrash() {
    // Zero-size shapes happen constantly: every drag starts as one.
    for kind: Annotation.Kind in [
        .rect(origin: CGPoint(x: 50, y: 50), size: .zero),
        .ellipse(origin: CGPoint(x: 50, y: 50), size: .zero),
        .highlight(origin: CGPoint(x: 50, y: 50), size: .zero),
        .blur(origin: CGPoint(x: 50, y: 50), size: .zero),
        .callout(origin: CGPoint(x: 50, y: 50), size: .zero, pointer: CGPoint(x: 50, y: 50), text: ""),
        .arrow(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 50, y: 50)),
        .pencil(points: []),
        .text(position: CGPoint(x: 50, y: 50), text: ""),
    ] {
        var canvas = Canvas(100, 100)
        AnnotationRenderer.draw(Annotation(kind: kind, color: red, width: 3), in: canvas.context)
        canvas.read()
        #expect(canvas.allInk == 0, "a degenerate shape left ink behind")
    }
}

@Test func rectIsStrokedAndFaintlyFilled() {
    // The 12% fill is what makes a rectangle grabbable in its middle rather
    // than only on its edge, so it has to actually be there — and it has to
    // stay faint enough to read the screenshot through.
    var canvas = Canvas()
    AnnotationRenderer.draw(
        Annotation(kind: .rect(origin: CGPoint(x: 40, y: 30), size: CGSize(width: 100, height: 50)),
                   color: red, width: 3),
        in: canvas.context)
    canvas.read()

    let (_, mg, mb) = canvas.rgb(90, 55)     // interior
    #expect(mg < 250 && mb < 250, "the interior fill is missing")
    #expect(mg > 200, "the interior fill is too opaque to see through")
    let (er, eg, _) = canvas.rgb(90, 30)     // top edge
    #expect(er > 200 && eg < 100, "the border is not the annotation colour")
}

@Test func wrapBreaksOnWordsAndKeepsHardNewlines() {
    let font = AnnotationRenderer.font(size: 14, bold: false)
    let lines = AnnotationRenderer.wrap("hello world again", font: font, width: 40)
    #expect(lines.count > 1)
    #expect(lines.allSatisfy { !$0.contains("\n") })
    #expect(lines.joined(separator: " ") == "hello world again")

    // A hard newline is a break the user typed; wrapping must not swallow it.
    #expect(AnnotationRenderer.wrap("a\nb", font: font, width: 1000) == ["a", "b"])
}

@Test func aWordTooLongToFitStillEmitsALine() {
    // Greedy wrapping must not loop or drop text when a single word is wider
    // than the bubble.
    let font = AnnotationRenderer.font(size: 14, bold: false)
    let lines = AnnotationRenderer.wrap("unbreakableword", font: font, width: 5)
    #expect(lines == ["unbreakableword"])
}

@Test func multiLineTextMeasuresAsABlockNotOneLongLine() {
    // Measuring a newline as a glyph makes a two-line label twice as wide and
    // half as tall, which breaks both its hit box and its backdrop plate.
    let one = "hello".measure(size: 18)
    let two = "hello\nhello".measure(size: 18)
    #expect(abs(two.width - one.width) < 0.5)
    #expect(two.height > one.height * 1.9)
}
