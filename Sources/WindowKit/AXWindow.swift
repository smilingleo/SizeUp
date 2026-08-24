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
        let before = frame()
        let target = axRect(fromCocoa: cocoaRect, primaryFrame: primaryFrame)
        writePoint(kAXPositionAttribute, target.origin)
        writeSize(kAXSizeAttribute, target.size)
        writePoint(kAXPositionAttribute, target.origin)
        let achieved = frame()
        report(before: before, request: cocoaRect, achieved: achieved)
        return achieved
    }

    /// Log the whole transition: what Accessibility said the window was, what it
    /// was asked for, and what it became.
    ///
    /// The first version logged only disagreements, which was the wrong choice
    /// and would have hidden the bug it was written for. A window given the
    /// *wrong screen's* frame accepts it perfectly — asked equals got, nothing
    /// to disagree about — and the only trace is that "before" was on one
    /// display and "asked" on another. Two of the three numbers were the
    /// interesting ones and they were the two not being logged.
    ///
    /// One line per window move, which is one line per deliberate keypress, so
    /// the volume is the user's own doing. The disagreement is still called out
    /// separately, at `problem` level, because "the application refused" is a
    /// different answer from "we asked for the wrong thing".
    private func report(before: CGRect?, request: CGRect, achieved: CGRect?) {
        let who = bundleIdentifier ?? "pid \(pid)"
        guard let achieved else {
            Log.problem("\(who) window frame unreadable after setFrame")
            return
        }
        Log.note("\(who) window was \(Self.text(before)) asked \(Self.text(request))"
            + " now \(Self.text(achieved))")

        // A point of tolerance rather than exact equality: Accessibility
        // positions are integral and a tiled frame need not be, so an honest
        // application still lands a fraction of a point away.
        let off = max(
            abs(achieved.minX - request.minX), abs(achieved.minY - request.minY),
            abs(achieved.width - request.width), abs(achieved.height - request.height)
        )
        guard off > 1 else { return }
        Log.problem("\(who) did not take the frame it was given,"
            + " off by \(Int(off.rounded()))pt")
    }

    private static func text(_ rect: CGRect?) -> String {
        guard let rect else { return "(unreadable)" }
        return "(\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
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
