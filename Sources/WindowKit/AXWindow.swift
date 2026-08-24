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
    public func setFrame(_ requested: CGRect) -> CGRect? {
        // Refuse rather than corrupt: see CGRect.isSafeToApply.
        guard requested.isSafeToApply else { return nil }
        let before = axFrame()
        let target = axRect(fromCocoa: requested, primaryFrame: primaryFrame)

        // Applied and verified in Accessibility space, then converted once for
        // the caller. Comparing in Cocoa space would be wrong: a window that
        // refuses to change height reads back at a different Cocoa y for that
        // reason alone, so the check would call a pure size failure a position
        // failure too, and the numbers in the log would not be subtractable.
        let applier = FrameApplier(
            read: { [weak self] in self?.axFrame() },
            writePosition: { [weak self] in self?.writePoint(kAXPositionAttribute, $0) },
            writeSize: { [weak self] in self?.writeSize(kAXSizeAttribute, $0) }
        )
        let (achieved, attempts) = applier.apply(target)

        report(before: before, request: target, achieved: achieved, attempts: attempts)
        guard let achieved else { return nil }
        return cocoaRect(fromAX: achieved, primaryFrame: primaryFrame)
    }

    /// The frame in Accessibility space, which is where the writes happen and so
    /// where they have to be checked.
    private func axFrame() -> CGRect? {
        guard let position = copyValue(kAXPositionAttribute, as: .cgPoint, CGPoint.self),
              let size = copyValue(kAXSizeAttribute, as: .cgSize, CGSize.self)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func report(before: CGRect?, request: CGRect, achieved: CGRect?, attempts: Int) {
        let who = bundleIdentifier ?? "pid \(pid)"
        guard let achieved else {
            Log.problem("\(who) window frame unreadable after setFrame")
            return
        }
        let tries = attempts > 1 ? " after \(attempts) attempts" : ""
        Log.note("\(who) window was \(Self.text(before)) asked \(Self.text(request))"
            + " now \(Self.text(achieved))\(tries) [Accessibility space]")

        let off = FrameApplier.offset(of: achieved, from: request)
        guard off > 1 else { return }
        Log.problem("\(who) did not take the frame it was given,"
            + " off by \(Int(off.rounded()))pt after \(attempts) attempts")
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
