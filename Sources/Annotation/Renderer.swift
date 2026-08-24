import CoreGraphics
import CoreText
import Foundation

/// Draws annotations into a CGContext.
///
/// **The context must be top-left-origin (flipped).** Annotation coordinates
/// are the overlay view's, and that view is flipped to match Rust, so a
/// bottom-up context renders every shape mirrored and every glyph upside down.
/// The overlay gets this for free (a flipped `NSView`'s context is already
/// top-left); an export path drawing into a fresh bitmap must establish it
/// (`translateBy(x: 0, y: h)` then `scaleBy(x: 1, y: -1)`) before calling in.
///
/// Text is CoreText, not AppKit, so this renderer works in the overlay *and*
/// in the PNG export without the `Annotation` target reaching for AppKit.
public enum AnnotationRenderer {
    // Matching the Rust renderer exactly — these numbers are the look.
    static let shapeFillAlpha: CGFloat = 0.12
    static let rectCornerRadius: CGFloat = 8
    static let arrowAngle: CGFloat = 0.4
    static let blurBlockSize: CGFloat = 10

    /// Draw a whole annotation list in order.
    ///
    /// Step numbers are assigned here, by position among the steps, because the
    /// model deliberately does not store them: numbering is a property of
    /// render order, so deleting step 2 renumbers the rest without touching a
    /// single stored shape.
    public static func draw(
        _ annotations: [Annotation],
        in ctx: CGContext,
        blurSource: CGImage? = nil,
        blurScale: CGFloat = 1
    ) {
        var step = 0
        for annotation in annotations {
            if case .step = annotation.kind { step += 1 }
            draw(annotation, stepNumber: step, in: ctx, blurSource: blurSource, blurScale: blurScale)
        }
    }

    public static func draw(
        _ annotation: Annotation,
        stepNumber: Int = 1,
        in ctx: CGContext,
        blurSource: CGImage? = nil,
        blurScale: CGFloat = 1
    ) {
        let color = annotation.color
        let width = annotation.width
        switch annotation.kind {
        case let .arrow(start, end):
            drawArrow(ctx, start, end, color, width)
        case let .rect(origin, size):
            drawRect(ctx, origin, size, color, width)
        case let .ellipse(origin, size):
            drawEllipse(ctx, origin, size, color, width)
        case let .pencil(points):
            drawPencil(ctx, points, color, width)
        case let .text(position, text):
            drawTextAnnotation(ctx, position, text, color, annotation.fontSize)
        case let .callout(origin, size, pointer, text):
            drawCallout(ctx, origin, size, pointer, text, color, width, annotation.fontSize)
        case let .highlight(origin, size):
            drawHighlight(ctx, origin, size, color, annotation.opacity)
        case let .step(center, radius):
            drawStep(ctx, center, stepNumber, color, radius)
        case let .blur(origin, size):
            drawBlur(ctx, origin, size, source: blurSource, scale: blurScale)
        }
    }

    // MARK: Shapes

    private static func drawArrow(
        _ ctx: CGContext, _ start: CGPoint, _ end: CGPoint, _ color: AnnotationColor, _ width: CGFloat
    ) {
        let d = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let len = (d.x * d.x + d.y * d.y).squareRoot()

        // A zero-length arrow draws nothing. Rust strokes it anyway, and a
        // round line cap on an empty path paints a small dot — but a zero-size
        // annotation has an empty bounding rect, so that dot cannot be hit,
        // selected or deleted. One stray click would leave a permanent speck.
        // Deliberate divergence from the oracle.
        guard len > 1 else { return }

        // Stop the shaft at the arrowhead base so a round cap cannot poke
        // through the filled triangle.
        let head = headLength(width: width, length: len)
        let angle = atan2(d.y, d.x)
        let shaftEnd = CGPoint(x: end.x - head * cos(angle), y: end.y - head * sin(angle))

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.restoreGState()

        drawArrowHead(ctx, start, end, color, width)
    }

    private static func headLength(width: CGFloat, length: CGFloat) -> CGFloat {
        min(max(width * 4, 12), length * 0.35)
    }

    private static func drawArrowHead(
        _ ctx: CGContext, _ start: CGPoint, _ end: CGPoint, _ color: AnnotationColor, _ width: CGFloat
    ) {
        let d = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        guard len > 1 else { return }
        let head = headLength(width: width, length: len)
        let angle = atan2(d.y, d.x)
        let p1 = CGPoint(x: end.x - head * cos(angle - arrowAngle),
                         y: end.y - head * sin(angle - arrowAngle))
        let p2 = CGPoint(x: end.x - head * cos(angle + arrowAngle),
                         y: end.y - head * sin(angle + arrowAngle))
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.move(to: end)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawRect(
        _ ctx: CGContext, _ origin: CGPoint, _ size: CGSize, _ color: AnnotationColor, _ width: CGFloat
    ) {
        let norm = Annotation.normalizeRect(origin, size)
        ctx.saveGState()
        ctx.setFillColor(color.cgColor(alpha: shapeFillAlpha))
        addRoundedRect(ctx, norm, rectCornerRadius)
        ctx.fillPath()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        addRoundedRect(ctx, norm, rectCornerRadius)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawEllipse(
        _ ctx: CGContext, _ origin: CGPoint, _ size: CGSize, _ color: AnnotationColor, _ width: CGFloat
    ) {
        let norm = Annotation.normalizeRect(origin, size)
        ctx.saveGState()
        ctx.setFillColor(color.cgColor(alpha: shapeFillAlpha))
        ctx.fillEllipse(in: norm)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokeEllipse(in: norm)
        ctx.restoreGState()
    }

    private static func drawPencil(
        _ ctx: CGContext, _ points: [CGPoint], _ color: AnnotationColor, _ width: CGFloat
    ) {
        // Two points minimum, for the same reason as the zero-length arrow: a
        // single-point polyline is an unhittable dot.
        guard points.count >= 2, let first = points.first else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawHighlight(
        _ ctx: CGContext, _ origin: CGPoint, _ size: CGSize, _ color: AnnotationColor, _ opacity: CGFloat
    ) {
        let norm = Annotation.normalizeRect(origin, size)
        guard norm.width >= 1, norm.height >= 1 else { return }

        // Two-layer marker-pen effect: a soft wide layer under a denser inset
        // one. Reads like a physical highlighter rather than a flat alpha fill.
        let inset = min(max(min(norm.width, norm.height) * 0.08, 1), 3)
        let inner = norm.insetBy(dx: inset, dy: inset)

        ctx.saveGState()
        ctx.setFillColor(color.cgColor(alpha: min(opacity * 0.55, 1)))
        addRoundedRect(ctx, norm, 3)
        ctx.fillPath()
        if inner.width > 0, inner.height > 0 {
            ctx.setFillColor(color.cgColor(alpha: opacity))
            addRoundedRect(ctx, inner, 2)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawStep(
        _ ctx: CGContext, _ center: CGPoint, _ number: Int, _ color: AnnotationColor, _ radius: CGFloat
    ) {
        let circle = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()

        // Crisp inner ring for contrast against busy backgrounds.
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.setLineWidth(max(radius * 0.08, 1))
        ctx.strokeEllipse(in: circle.insetBy(dx: 2, dy: 2))
        ctx.restoreGState()

        let fontSize = number >= 10 ? radius * 0.95 : radius * 1.15
        let label = "\(number)"
        let font = Self.font(size: fontSize, bold: true)
        let size = measure(label, font: font)
        drawLine(ctx, label, font: font,
                 at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                 color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    }

    private static func drawBlur(
        _ ctx: CGContext, _ origin: CGPoint, _ size: CGSize, source: CGImage?, scale: CGFloat
    ) {
        let norm = Annotation.normalizeRect(origin, size)
        guard norm.width >= 1, norm.height >= 1 else { return }

        guard let source, let pixelated = pixelate(source, norm, scale) else {
            // No source to sample: fall back to an opaque grey so a blur is
            // never a silent no-op that leaks what it was meant to hide.
            ctx.saveGState()
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(norm)
            ctx.restoreGState()
            return
        }

        ctx.saveGState()
        ctx.clip(to: norm)
        // The context is top-left-origin, so an image drawn straight in lands
        // upside down; flip within the destination rect.
        ctx.translateBy(x: norm.minX, y: norm.minY + norm.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(pixelated, in: CGRect(origin: .zero, size: norm.size))
        ctx.restoreGState()
    }

    /// Crop the region out of the source and mosaic it.
    private static func pixelate(_ source: CGImage, _ rect: CGRect, _ scale: CGFloat) -> CGImage? {
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                        width: rect.width * scale, height: rect.height * scale)
        let clamped = px.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard clamped.width >= 1, clamped.height >= 1,
              let crop = source.cropping(to: clamped) else { return nil }

        let blocks = max(1, blurBlockSize * scale)
        let w = max(1, Int(CGFloat(crop.width) / blocks))
        let h = max(1, Int(CGFloat(crop.height) / blocks))
        guard let small = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return small.makeImage()
    }

    // MARK: Text

    private static func drawTextAnnotation(
        _ ctx: CGContext, _ position: CGPoint, _ text: String, _ color: AnnotationColor, _ fontSize: CGFloat
    ) {
        guard !text.isEmpty else { return }
        drawTextBackdrop(ctx, position, text, fontSize)

        let font = Self.font(size: fontSize, bold: false)
        let lineHeight = fontSize * 1.3
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            drawLine(ctx, String(line), font: font,
                     at: CGPoint(x: position.x, y: position.y + CGFloat(i) * lineHeight),
                     color: color.cgColor)
        }
    }

    /// A translucent plate behind text so it stays legible on any wallpaper.
    private static func drawTextBackdrop(
        _ ctx: CGContext, _ position: CGPoint, _ text: String, _ fontSize: CGFloat
    ) {
        let size = text.measure(size: fontSize)
        guard size.width >= 1, size.height >= 1 else { return }
        let padX: CGFloat = 4, padY: CGFloat = 2
        let bg = CGRect(x: position.x - padX, y: position.y - padY,
                        width: size.width + padX * 2, height: size.height + padY * 2)
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
        addRoundedRect(ctx, bg, 4)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.15))
        ctx.setLineWidth(1)
        addRoundedRect(ctx, bg, 4)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawCallout(
        _ ctx: CGContext, _ origin: CGPoint, _ size: CGSize, _ pointer: CGPoint,
        _ text: String, _ color: AnnotationColor, _ width: CGFloat, _ fontSize: CGFloat
    ) {
        let bubble = Annotation.normalizeRect(origin, size)
        guard bubble.width >= 10, bubble.height >= 10 else { return }
        let anchor = Annotation.calloutAnchorPoint(origin: origin, size: size, pointer: pointer)

        // Stem, stopping at the arrowhead base like the arrow tool does.
        let d = CGPoint(x: pointer.x - anchor.x, y: pointer.y - anchor.y)
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        let stemEnd: CGPoint
        if len > 1 {
            let head = headLength(width: width, length: len)
            let angle = atan2(d.y, d.x)
            stemEnd = CGPoint(x: pointer.x - head * cos(angle), y: pointer.y - head * sin(angle))
        } else {
            stemEnd = pointer
        }

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.move(to: anchor)
        ctx.addLine(to: stemEnd)
        ctx.strokePath()
        ctx.restoreGState()
        drawArrowHead(ctx, anchor, pointer, color, width)

        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
        addRoundedRect(ctx, bubble, 9)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(max(width, 1.5))
        addRoundedRect(ctx, bubble, 9)
        ctx.strokePath()
        ctx.restoreGState()

        guard !text.isEmpty else { return }
        let textRect = CGRect(x: bubble.minX + 10, y: bubble.minY + 8,
                             width: max(bubble.width - 20, 1), height: max(bubble.height - 16, 1))
        drawWrapped(ctx, text, in: textRect, fontSize: fontSize,
                    color: CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
    }

    /// Word-wrapped text inside a rect, clipped to it.
    private static func drawWrapped(
        _ ctx: CGContext, _ text: String, in rect: CGRect, fontSize: CGFloat, color: CGColor
    ) {
        let font = Self.font(size: fontSize, bold: false)
        let lineHeight = fontSize * 1.3
        ctx.saveGState()
        ctx.clip(to: rect)
        var y = rect.minY
        for line in wrap(text, font: font, width: rect.width) {
            if y > rect.maxY { break }
            drawLine(ctx, line, font: font, at: CGPoint(x: rect.minX, y: y), color: color)
            y += lineHeight
        }
        ctx.restoreGState()
    }

    /// Greedy word wrap. CoreText could do this with a framesetter, but a
    /// framesetter also wants a flipped path and its own coordinate dance; for
    /// a callout bubble the greedy result is identical and far easier to test.
    static func wrap(_ text: String, font: CTFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if measure(candidate, font: font).width <= width || current.isEmpty {
                    current = candidate
                } else {
                    lines.append(current)
                    current = String(word)
                }
            }
            lines.append(current)
        }
        return lines
    }

    /// Draw one line with its **top-left** at `point`, upright, in a
    /// top-left-origin context.
    private static func drawLine(
        _ ctx: CGContext, _ text: String, font: CTFont, at point: CGPoint, color: CGColor
    ) {
        guard !text.isEmpty else { return }
        // kCTFontAttributeName is literally "NSFont" — naming both is a
        // duplicate key and traps at runtime.
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))

        ctx.saveGState()
        ctx.textMatrix = .identity
        // The context grows y downward; glyphs are built y-up. Move to the
        // baseline, then flip so the glyphs come out the right way round.
        ctx.translateBy(x: point.x, y: point.y + CTFontGetAscent(font))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    static func measure(_ text: String, font: CTFont) -> CGSize {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.init(kCTFontAttributeName as String): font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: width, height: ascent + descent)
    }

    // MARK: Paths

    static func addRoundedRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat) {
        let r = min(radius, min(rect.width, rect.height) / 2)
        guard r > 0 else { ctx.addRect(rect); return }
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: minX + r, y: minY))
        ctx.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)
        ctx.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY), radius: r)
        ctx.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)
        ctx.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
        ctx.closePath()
    }
}
