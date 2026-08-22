import CoreGraphics
import CoreText
import Foundation

/// An sRGB color. A `CGColor` rather than a tuple: it is `Hashable`/`Codable`,
/// so an annotation that stores one round-trips and equates without a custom
/// conformance, and the renderer consumes it directly.
public struct AnnotationColor: Hashable, Codable, Sendable {
    public let r: CGFloat
    public let g: CGFloat
    public let b: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var cgColor: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

    /// The nine swatches the style panel offers, in the Rust ClipShot order
    /// (values transcribed from `style_panel.rs`, not recolored).
    public static let choices: [AnnotationColor] = [
        AnnotationColor(r: 1.0, g: 0.18, b: 0.45),  // Pink
        AnnotationColor(r: 1.0, g: 0.42, b: 0.0),   // Orange
        AnnotationColor(r: 1.0, g: 0.72, b: 0.0),   // Yellow
        AnnotationColor(r: 0.0, g: 0.82, b: 0.45),  // Green
        AnnotationColor(r: 0.0, g: 0.75, b: 0.82),  // Cyan
        AnnotationColor(r: 0.45, g: 0.28, b: 0.95), // Purple
        AnnotationColor(r: 0.48, g: 0.51, b: 0.54), // Gray
        AnnotationColor(r: 0.12, g: 0.12, b: 0.12), // Black
        AnnotationColor(r: 0.96, g: 0.97, b: 0.98), // White
    ]
}

/// The stroke widths the style panel offers (keys 1/2/3), and the font-size
/// range the text tools use. Values from the Rust `style_panel.rs`.
public enum AnnotationStyle {
    public static let strokeThin: CGFloat = 1.5
    public static let strokeMedium: CGFloat = 3.0
    public static let strokeThick: CGFloat = 5.5

    public static let fontSizes: ClosedRange<CGFloat> = 12...48
    public static let defaultFontSize: CGFloat = 18
    /// Callout font size is intentionally independent of the text tool's.
    public static let defaultCalloutFontSize: CGFloat = 18

    public static func strokeWidth(preset: Int) -> CGFloat {
        switch preset {
        case 0: return strokeThin
        case 2: return strokeThick
        default: return strokeMedium
        }
    }
}

/// The eleven tools the canvas offers, in toolbar order.
///
/// `select` and `crop` are *actions* rather than stored shapes: the stored
/// annotation model has one case per drawable shape (nine). The toolbar's
/// button layout and the tool hotkeys (S/A/R/E/P/T/Q/H/N/B/C) key off this list.
public enum Tool: String, CaseIterable, Sendable {
    case select, arrow, rectangle, ellipse, pencil, text, callout, highlight, step, blur, crop

    public var shortcutKey: Character {
        switch self {
        case .select: return "s"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .pencil: return "p"
        case .text: return "t"
        case .callout: return "q"
        case .highlight: return "h"
        case .step: return "n"
        case .blur: return "b"
        case .crop: return "c"
        }
    }
}

/// A resize handle on a stored annotation. The indices double as the hit-test
/// priority order: handles are checked in declaration order, so a corner
/// claimed by two shapes at a shared edge resolves deterministically.
public enum HandleKind: Int, Hashable, Sendable {
    case arrowStart, arrowEnd
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
    case calloutPointer
}

/// One annotation on the capture canvas.
///
/// Top-left origin coordinates, in the overlay's logical (point) space — the
/// same space the Rust model uses; the renderer and the crop-and-composite
/// path convert to pixels with the display's backing scale at the boundary.
///
/// `kind` holds the shape; `color`, `width`, `fontSize`, `opacity` are the
/// shared style fields, each with a per-kind meaning (a text annotation uses
/// `fontSize`, a highlight uses `opacity`, shapes use `width`). Step numbers
/// are *not* stored: numbering is a render-order property, so renumbering the
/// visible steps does not touch the model and two steps still encode
/// identically.
public struct Annotation: Equatable, Hashable, Codable, Sendable {
    public enum Kind: Equatable, Hashable, Codable, Sendable {
        case arrow(start: CGPoint, end: CGPoint)
        case rect(origin: CGPoint, size: CGSize)
        case ellipse(origin: CGPoint, size: CGSize)
        case pencil(points: [CGPoint])
        case text(position: CGPoint, text: String)
        case callout(origin: CGPoint, size: CGSize, pointer: CGPoint, text: String)
        case highlight(origin: CGPoint, size: CGSize)
        case step(center: CGPoint, radius: CGFloat)
        case blur(origin: CGPoint, size: CGSize)
    }

    public var kind: Kind
    public var color: AnnotationColor
    public var width: CGFloat
    public var fontSize: CGFloat
    public var opacity: CGFloat

    public init(
        kind: Kind,
        color: AnnotationColor = AnnotationColor.choices[0],
        width: CGFloat = AnnotationStyle.strokeMedium,
        fontSize: CGFloat = AnnotationStyle.defaultFontSize,
        opacity: CGFloat = 1
    ) {
        self.kind = kind
        self.color = color
        self.width = width
        self.fontSize = fontSize
        self.opacity = opacity
    }

    // MARK: Bounding and hit-testing

    /// Padding added to bounding rects for hit-testing tolerance.
    private static let hitTestPadding: CGFloat = 4
    /// Tolerance for hitting a resize handle.
    private static let handleHitTolerance: CGFloat = 6

    public func boundingRect() -> CGRect {
        switch kind {
        case let .arrow(start, end):
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            return rect.inflate(width)
        case let .rect(origin, size):
            return Annotation.normalizeRect(origin, size).inflate(width)
        case let .ellipse(origin, size):
            return Annotation.normalizeRect(origin, size).inflate(width)
        case let .pencil(points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points.dropFirst() {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).inflate(width)
        case let .text(position, text):
            let size = text.measure(size: fontSize)
            return CGRect(origin: position, size: size)
        case let .callout(origin, size, pointer, _):
            let bubble = Annotation.normalizeRect(origin, size).inflate(width + 4)
            let anchor = Annotation.calloutAnchorPoint(origin: origin, size: size, pointer: pointer)
            let pointerRect = CGRect(
                x: min(anchor.x, pointer.x), y: min(anchor.y, pointer.y),
                width: abs(anchor.x - pointer.x), height: abs(anchor.y - pointer.y)
            ).inflate(width + Self.hitTestPadding)
            return bubble.unite(pointerRect)
        case let .highlight(origin, size):
            return Annotation.normalizeRect(origin, size)
        case let .step(center, radius):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case let .blur(origin, size):
            return Annotation.normalizeRect(origin, size)
        }
    }

    /// Whether a point hits this annotation, with tolerance. Arrows and
    /// callout pointers test against their segments; everything else against
    /// the padded bounding rect.
    public func hitTest(_ point: CGPoint) -> Bool {
        switch kind {
        case let .arrow(start, end):
            return point.distance(toSegment: start, end: end) <= max(width + Self.hitTestPadding, 8)
        case let .callout(origin, size, pointer, _):
            let bubble = Annotation.normalizeRect(origin, size).inflate(Self.hitTestPadding)
            let anchor = Annotation.calloutAnchorPoint(origin: origin, size: size, pointer: pointer)
            return point.isIn(bubble) || point.distance(toSegment: anchor, end: pointer) <= max(width + Self.hitTestPadding, 8)
        default:
            return point.isIn(boundingRect().inflate(Self.hitTestPadding))
        }
    }

    // MARK: Handles and resizing

    /// The drag handles this annotation supports; empty for shapes without
    /// resizable geometry (pencil, text).
    public func resizeHandles() -> [(HandleKind, CGPoint)] {
        switch kind {
        case let .arrow(start, end):
            return [(.arrowStart, start), (.arrowEnd, end)]
        case let .rect(origin, size), let .ellipse(origin, size),
             let .highlight(origin, size), let .blur(origin, size):
            return Self.rectHandles(Annotation.normalizeRect(origin, size))
        case let .callout(origin, size, pointer, _):
            var handles = Self.rectHandles(Annotation.normalizeRect(origin, size))
            handles.append((.calloutPointer, pointer))
            return handles
        case .pencil, .text, .step:
            return []
        }
    }

    /// The handle within tolerance of `point`, if any.
    public func hitTestHandle(_ point: CGPoint) -> HandleKind? {
        resizeHandles().first { point.distance(to: $0.1) <= Self.handleHitTolerance }?.0
    }

    /// Move a handle (or the whole callout pointer) to `point`.
    public mutating func applyResize(_ handle: HandleKind, to point: CGPoint) {
        switch kind {
        case var .arrow(start, end):
            switch handle {
            case .arrowStart: start = point
            case .arrowEnd: end = point
            default: break
            }
            kind = .arrow(start: start, end: end)
        case var .rect(origin, size), var .ellipse(origin, size),
             var .highlight(origin, size), var .blur(origin, size):
            let r = Annotation.normalizeRect(origin, size)
            let newR = Self.applyRectResize(r, handle: handle, to: point)
            (origin, size) = (newR.origin, newR.size)
            switch kind {
            case .rect: kind = .rect(origin: origin, size: size)
            case .ellipse: kind = .ellipse(origin: origin, size: size)
            case .highlight: kind = .highlight(origin: origin, size: size)
            case .blur: kind = .blur(origin: origin, size: size)
            default: break
            }
        case var .callout(origin, size, pointer, text):
            if handle == .calloutPointer {
                pointer = point
            } else {
                let newR = Self.applyRectResize(Annotation.normalizeRect(origin, size), handle: handle, to: point)
                let norm = Annotation.normalizeRect(newR.origin, newR.size)
                origin = norm.origin
                size = CGSize(width: max(norm.size.width, 60), height: max(norm.size.height, 32))
            }
            kind = .callout(origin: origin, size: size, pointer: pointer, text: text)
        default:
            break
        }
    }

    /// Move the whole annotation by a delta.
    public mutating func translate(dx: CGFloat, dy: CGFloat) {
        switch kind {
        case var .arrow(start, end):
            start.x += dx; start.y += dy; end.x += dx; end.y += dy
            kind = .arrow(start: start, end: end)
        case var .rect(origin, size), var .ellipse(origin, size), var .highlight(origin, size),
             var .blur(origin, size):
            origin.x += dx; origin.y += dy
            switch kind {
            case .rect: kind = .rect(origin: origin, size: size)
            case .ellipse: kind = .ellipse(origin: origin, size: size)
            case .highlight: kind = .highlight(origin: origin, size: size)
            case .blur: kind = .blur(origin: origin, size: size)
            default: break
            }
        case var .pencil(points):
            for i in points.indices { points[i].x += dx; points[i].y += dy }
            kind = .pencil(points: points)
        case var .text(position, text):
            position.x += dx; position.y += dy
            kind = .text(position: position, text: text)
        case var .callout(origin, size, pointer, text):
            origin.x += dx; origin.y += dy; pointer.x += dx; pointer.y += dy
            kind = .callout(origin: origin, size: size, pointer: pointer, text: text)
        case var .step(center, radius):
            center.x += dx; center.y += dy
            kind = .step(center: center, radius: radius)
        }
    }

    /// Update an in-progress annotation with a new mouse position while
    /// drawing. Callouts re-derive their bubble from the pointer each move.
    public mutating func update(with point: CGPoint) {
        switch kind {
        case var .arrow(start, _):
            kind = .arrow(start: start, end: point)
        case var .rect(origin, _), var .ellipse(origin, _), var .highlight(origin, _),
             var .blur(origin, _):
            let size = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            switch kind {
            case .rect: kind = .rect(origin: origin, size: size)
            case .ellipse: kind = .ellipse(origin: origin, size: size)
            case .highlight: kind = .highlight(origin: origin, size: size)
            case .blur: kind = .blur(origin: origin, size: size)
            default: break
            }
        case var .pencil(points):
            points.append(point)
            kind = .pencil(points: points)
        case var .text(position, text):
            _ = (position, text) // placed on click; drag moves it
            kind = .text(position: point, text: text)
        case var .callout(origin, size, pointer, text):
            let draft = Annotation.calloutDraft(
                pointer: pointer, bubbleAnchor: point, color: color, width: width, fontSize: fontSize
            )
            origin = draft.0
            size = draft.1
            kind = .callout(origin: origin, size: size, pointer: pointer, text: text)
        case var .step(center, radius):
            kind = .step(center: point, radius: radius)
        }
    }

    // MARK: Callout geometry

    /// Where on the bubble's border the pointer segment attaches: the point on
    /// the border closest to the pointer direction, so the segment never
    /// crosses the bubble.
    public static func calloutAnchorPoint(origin: CGPoint, size: CGSize, pointer: CGPoint) -> CGPoint {
        let r = Annotation.normalizeRect(origin, size)
        let center = CGPoint(x: r.midX, y: r.midY)
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        guard !(abs(dx) < 0.001 && abs(dy) < 0.001) else {
            return CGPoint(x: center.x, y: r.maxY)
        }
        let sx = abs(dx) < 0.001 ? CGFloat.infinity : (r.size.width / 2) / abs(dx)
        let sy = abs(dy) < 0.001 ? CGFloat.infinity : (r.size.height / 2) / abs(dy)
        let scale = min(sx, sy)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    /// The bubble rect for a callout drag from `pointer` toward
    /// `bubbleAnchor`, with the same minimum sizes and gap the Rust model uses.
    static func calloutDraft(
        pointer: CGPoint, bubbleAnchor: CGPoint,
        color: AnnotationColor, width: CGFloat, fontSize: CGFloat
    ) -> (CGPoint, CGSize) {
        let dx = bubbleAnchor.x - pointer.x
        let dy = bubbleAnchor.y - pointer.y
        let minW: CGFloat = 168
        let minH = max(fontSize * 2.4, 58)
        let gap: CGFloat = 18

        let w = max(abs(dx), minW)
        let h = min(max(abs(dy) * 0.65, minH), 140)
        let originX = dx >= 0
            ? max(bubbleAnchor.x, pointer.x + gap)
            : min(bubbleAnchor.x - w, pointer.x - gap - w)
        let originY = dy >= 0
            ? max(bubbleAnchor.y, pointer.y + gap)
            : min(bubbleAnchor.y - h, pointer.y - gap - h)
        return (CGPoint(x: originX, y: originY), CGSize(width: w, height: h))
    }
}

// MARK: - Geometry helpers (the shared primitives)

extension CGRect {
    /// Grow on all sides by `amount` (negative shrinks).
    public func inflate(_ amount: CGFloat) -> CGRect {
        CGRect(x: origin.x - amount, y: origin.y - amount,
               width: size.width + amount * 2, height: size.height + amount * 2)
    }

    /// Smallest rect containing both. Named `unite`: CoreGraphics already
    /// provides `CGRect.union(_:)`, so the same name would be a collision.
    public func unite(_ other: CGRect) -> CGRect {
        CGRect(
            x: min(minX, other.minX), y: min(minY, other.minY),
            width: max(maxX, other.maxX) - min(minX, other.minX),
            height: max(maxY, other.maxY) - min(minY, other.minY)
        )
    }
}

extension CGPoint {
    public func isIn(_ rect: CGRect) -> Bool {
        x >= rect.minX && x <= rect.maxX && y >= rect.minY && y <= rect.maxY
    }

    public func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    /// Shortest distance to the segment `start`–`end`.
    public func distance(toSegment start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.0001 else { return distance(to: start) }
        let t = max(0, min(1, ((x - start.x) * dx + (y - start.y) * dy) / lenSq))
        let closest = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return distance(to: closest)
    }
}

extension String {
    /// The rendered size of this string in the system font, via CoreText —
    /// AppKit-free (probe-verified: `CTLineGetTypographicBounds` on a
    /// `CFAttributedString` measures with the same system-font metrics the
    /// Rust app got from `NSFont`). Empty text measures to zero.
    func measure(size fontSize: CGFloat) -> CGSize {
        guard !isEmpty,
              let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
        else { return .zero }
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, self as CFString, attributes) else {
            return .zero
        }
        let line = CTLineCreateWithAttributedString(attributed)
        return CGSize(
            width: ceil(CTLineGetTypographicBounds(line, nil, nil, nil)),
            height: ceil(fontSize * 1.2)
        )
    }
}

public extension Annotation {
    /// A normalized (non-negative size) rect from an origin/size pair, which
    /// may be negative while a drag is in progress.
    static func normalizeRect(_ origin: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(
            x: size.width < 0 ? origin.x + size.width : origin.x,
            y: size.height < 0 ? origin.y + size.height : origin.y,
            width: abs(size.width), height: abs(size.height)
        )
    }

    /// Eight handles: four corners, four edge midpoints.
    static func rectHandles(_ r: CGRect) -> [(HandleKind, CGPoint)] {
        [(.topLeft, r.origin),
         (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.left, CGPoint(x: r.minX, y: r.midY)),
         (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
         (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
    }

    /// Move one handle of a normalized rect; the opposite edge anchors.
    static func applyRectResize(_ r: CGRect, handle: HandleKind, to point: CGPoint) -> CGRect {
        var x = r.minX, y = r.minY, w = r.size.width, h = r.size.height
        switch handle {
        case .topLeft: x = point.x; y = point.y; w = r.maxX - point.x; h = r.maxY - point.y
        case .top: y = point.y; h = r.maxY - point.y
        case .topRight: w = point.x - r.minX; y = point.y; h = r.maxY - point.y
        case .left: x = point.x; w = r.maxX - point.x
        case .right: w = point.x - r.minX
        case .bottomLeft: x = point.x; w = r.maxX - point.x; h = point.y - r.minY
        case .bottom: h = point.y - r.minY
        case .bottomRight: w = point.x - r.minX; h = point.y - r.minY
        default: break
        }
        return CGRect(x: min(x, x + w), y: min(y, y + h), width: abs(w), height: abs(h))
    }
}
