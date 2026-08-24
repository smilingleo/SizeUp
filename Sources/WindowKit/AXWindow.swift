import ApplicationServices
import CoreGraphics
import Diagnostics
import Foundation
import Geometry

/// A window addressed through the Accessibility API.
public final class AXWindow: WindowHandle {
    private let element: AXUIElement
    private let pid: pid_t
    private let primaryFrame: CGRect
    public let bundleIdentifier: String?

    public init(element: AXUIElement, pid: pid_t, primaryFrame: CGRect, bundleIdentifier: String?) {
        self.element = element
        self.pid = pid
        self.primaryFrame = primaryFrame
        self.bundleIdentifier = bundleIdentifier
    }

    public var key: WindowKey {
        WindowKey(pid: pid, elementHash: Int(bitPattern: CFHash(element)))
    }

    public func frame() -> CGRect? {
        guard let position = copyValue(kAXPositionAttribute, as: .cgPoint, CGPoint.self),
              let size = copyValue(kAXSizeAttribute, as: .cgSize, CGSize.self)
        else { return nil }
        return cocoaRect(fromAX: CGRect(origin: position, size: size), primaryFrame: primaryFrame)
    }

    /// Writes position, then size, then position again.
    ///
    /// The two attributes are separate writes, so an application can clamp the
    /// size and leave the window mispositioned; re-applying position afterwards
    /// fixes that. The achieved frame is read back and returned, because
    /// applications with minimum sizes will not honour the request exactly.
    @discardableResult
    public func setFrame(_ cocoaRect: CGRect) -> CGRect? {
        // Refuse rather than corrupt: see CGRect.isSafeToApply.
        guard cocoaRect.isSafeToApply else { return nil }
        let target = axRect(fromCocoa: cocoaRect, primaryFrame: primaryFrame)
        writePoint(kAXPositionAttribute, target.origin)
        writeSize(kAXSizeAttribute, target.size)
        writePoint(kAXPositionAttribute, target.origin)
        let achieved = frame()
        report(request: cocoaRect, achieved: achieved)
        return achieved
    }

    /// Log the cases where the application did not do as it was told.
    ///
    /// Only the disagreements, never the successes: a line per window move would
    /// be noise nobody reads, whereas "Slack refused" is the whole answer to the
    /// one complaint this code produces — "app X will not tile". Without it the
    /// refusal is invisible, because `setFrame` reports the achieved frame and
    /// every caller treats that as the truth (correctly — it is the truth).
    ///
    /// A point of tolerance rather than exact equality: Accessibility positions
    /// are integral and a tiled frame need not be, so an honest application
    /// still lands a fraction of a point away.
    private func report(request: CGRect, achieved: CGRect?) {
        let who = bundleIdentifier ?? "pid \(pid)"
        guard let achieved else {
            Log.problem("\(who) window frame unreadable after setFrame")
            return
        }
        let off = max(
            abs(achieved.minX - request.minX), abs(achieved.minY - request.minY),
            abs(achieved.width - request.width), abs(achieved.height - request.height)
        )
        guard off > 1 else { return }
        Log.problem("\(who) did not take the frame it was given."
            + " asked \(Self.text(request)) got \(Self.text(achieved))"
            + " off by \(Int(off.rounded()))pt")
    }

    private static func text(_ rect: CGRect) -> String {
        "(\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
            + " \(Int(rect.width.rounded()))x\(Int(rect.height.rounded())))"
    }

    private func copyValue<T>(_ attribute: String, as type: AXValueType, _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(value, type, out) else { return nil }
        return out.pointee
    }

    private func writePoint(_ attribute: String, _ value: CGPoint) {
        var mutable = value
        guard let axValue = AXValueCreate(.cgPoint, &mutable) else { return }
        AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
    }

    private func writeSize(_ attribute: String, _ value: CGSize) {
        var mutable = value
        guard let axValue = AXValueCreate(.cgSize, &mutable) else { return }
        AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
    }
}
