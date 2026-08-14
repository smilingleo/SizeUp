import ApplicationServices
import CoreGraphics
import Foundation

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
        WindowKey(pid: pid, elementHash: Int(CFHash(element)))
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
        let target = axRect(fromCocoa: cocoaRect, primaryFrame: primaryFrame)
        writePoint(kAXPositionAttribute, target.origin)
        writeSize(kAXSizeAttribute, target.size)
        writePoint(kAXPositionAttribute, target.origin)
        return frame()
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
