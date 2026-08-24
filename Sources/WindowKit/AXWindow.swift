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

    /// Writes position, then size, then position again, with the application's
    /// enhanced-user-interface mode suppressed for the duration if it has it on.
    ///
    /// The two attributes are separate writes, so an application can clamp the
    /// size and leave the window mispositioned; re-applying position afterwards
    /// fixes that. The achieved frame is read back and returned, because
    /// applications with minimum sizes will not honour the request exactly.
    ///
    /// See `FrameApplier.suppressingEnhancedUserInterface` for what that mode
    /// does to a frame change and what was measured.
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
            writeSize: { [weak self] in self?.writeSize(kAXSizeAttribute, $0) },
            suppressingEnhancedUserInterface: { [weak self] writes in
                guard let self else {
                    writes()
                    return
                }
                self.suppressingEnhancedUserInterface(writes)
            }
        )
        let achieved = applier.apply(target)

        report(before: before, request: target, achieved: achieved)
        guard let achieved else { return nil }
        return cocoaRect(fromAX: achieved, primaryFrame: primaryFrame)
    }

    /// The frame in Accessibility space, which is where the writes happen and so
    /// where they have to be checked.
    func axFrame() -> CGRect? {
        guard let position = copyValue(kAXPositionAttribute, as: .cgPoint, CGPoint.self),
              let size = copyValue(kAXSizeAttribute, as: .cgSize, CGSize.self)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func report(before: CGRect?, request: CGRect, achieved: CGRect?) {
        let who = bundleIdentifier ?? "pid \(pid)"
        guard let achieved else {
            Log.problem("\(who) window frame unreadable after setFrame")
            return
        }
        Log.note("\(who) window was \(Self.text(before)) asked \(Self.text(request))"
            + " now \(Self.text(achieved)) [Accessibility space]")

        let off = FrameApplier.offset(of: achieved, from: request)
        guard off > 1 else { return }
        Log.problem("\(who) did not take the frame it was given,"
            + " off by \(Int(off.rounded()))pt")
        logProfile()
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
        record(AXUIElementSetAttributeValue(element, attribute as CFString, axValue), attribute)
    }

    private func writeSize(_ attribute: String, _ value: CGSize) {
        var mutable = value
        guard let axValue = AXValueCreate(.cgSize, &mutable) else { return }
        record(AXUIElementSetAttributeValue(element, attribute as CFString, axValue), attribute)
    }

    // MARK: - Enhanced user interface

    /// The attribute an assistive client sets on an application to ask for
    /// richer accessibility, and which some applications answer by animating
    /// their window frame changes. Not exposed to Swift as a constant.
    /// A `String` cast at each use site, like every other attribute name in
    /// this file: a `static let` of `CFString` is not `Sendable` and the strict
    /// concurrency checks reject it.
    private static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// The application this window belongs to. `AXEnhancedUserInterface` lives
    /// there, not on the window, which is why this exists at all.
    ///
    /// Built per action rather than held: an `AXWindow` is created fresh for
    /// every action, so there is nothing to cache it in and no staleness to
    /// worry about.
    private var application: AXUIElement { AXUIElementCreateApplication(pid) }

    /// Turns the mode off around `writes`, and only for an application that had
    /// it on.
    ///
    /// The read comes first so that nothing is written to an application that
    /// was already in the plain mode — the applications that have always tiled
    /// correctly are exactly those, and they must stay untouched.
    ///
    /// The restore is in a `defer` because the alternative is leaving another
    /// application's accessibility degraded for the rest of its lifetime if
    /// anything in between goes wrong. Two writes to somebody else's process is
    /// already more than this app likes to do; leaking one is not acceptable.
    private func suppressingEnhancedUserInterface(_ writes: () -> Void) {
        guard enhancedUserInterfaceIsOn else {
            writes()
            return
        }
        setEnhancedUserInterface(false)
        defer { setEnhancedUserInterface(true) }
        writes()
    }

    private var enhancedUserInterfaceIsOn: Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, Self.enhancedUserInterface as CFString, &raw
        ) == .success else { return false }
        return (raw as? Bool) == true
    }

    /// Deliberately does not go through `record`, and deliberately ignores the
    /// `AXError`.
    ///
    /// This write reports `kAXErrorNotImplemented` (-25208) and takes effect
    /// anyway: measured by writing `false`, reading the attribute back as
    /// `false`, writing `true`, and reading it back as `true`, on the same
    /// application whose windows then resized correctly. Logging that as a
    /// refusal would put a false problem line in the log on every single window
    /// action for such an application, and checking it would make the fix skip
    /// itself.
    private func setEnhancedUserInterface(_ on: Bool) {
        let value = (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        _ = AXUIElementSetAttributeValue(
            application, Self.enhancedUserInterface as CFString, value
        )
    }

    /// The return value of an Accessibility write, which used to be discarded.
    ///
    /// Discarding it made two very different failures look identical: a write
    /// the application rejected, and a write it accepted and then ignored. Only
    /// the second is the application's own doing, and only the first can be
    /// fixed by asking differently, so the distinction decides where to look.
    private func record(_ status: AXError, _ attribute: String) {
        guard status != .success else { return }
        let who = bundleIdentifier ?? "pid \(pid)"
        Log.problem("\(who) refused a \(attribute) write with AXError \(status.rawValue)")
    }

    /// What the window says about itself, logged only when it has just refused a
    /// frame — one line, and only on the path that is already going wrong.
    ///
    /// Every field here answers a hypothesis that would otherwise need a guess.
    /// A window in native full screen has a read-only size, and Accessibility
    /// will say so through `AXUIElementIsAttributeSettable` rather than through
    /// an error on the write. A minimised or non-standard window is not the one
    /// the user is looking at. No title is logged: see `Log`'s note on what this
    /// application does and does not put in the system log.
    private func logProfile() {
        let who = bundleIdentifier ?? "pid \(pid)"
        let fields = [
            "position settable \(settable(kAXPositionAttribute))",
            "size settable \(settable(kAXSizeAttribute))",
            // Spelled out because the constant is not exposed to Swift. This is
            // the attribute that goes read-only in native full screen, which
            // would explain a refusal that reports no error.
            "full screen \(text(flag("AXFullScreen")))",
            "minimised \(text(flag(kAXMinimizedAttribute)))",
            // On the application, not the window. Logged because a refusal from
            // an application that has this on is the known animation case, and a
            // refusal from one that does not is something new — and `setFrame`
            // has already suppressed it, so seeing it here means suppressing was
            // not enough.
            "enhanced UI \(enhancedUserInterfaceIsOn)",
            "role \(string(kAXRoleAttribute) ?? "?")/\(string(kAXSubroleAttribute) ?? "?")",
            "app windows \(windowCount.map(String.init) ?? "?")",
        ]
        Log.problem("\(who) window profile: " + fields.joined(separator: ", "))
    }

    private func settable(_ attribute: String) -> Bool {
        var result = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &result) == .success
        else { return false }
        return result.boolValue
    }

    private func flag(_ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw as? Bool
        else { return nil }
        return value
    }

    private func string(_ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success
        else { return nil }
        return raw as? String
    }

    /// How many windows Accessibility thinks the application has. A large number
    /// is how an application with hidden helper windows looks, and it is the one
    /// remaining way for the wrong window to have been picked.
    private var windowCount: Int? {
        var raw: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success
        else { return nil }
        return (raw as? [AXUIElement])?.count
    }

    private func text(_ flag: Bool?) -> String {
        guard let flag else { return "unknown" }
        return flag ? "yes" : "no"
    }
}


// MARK: - Raw writes, for the write-order probe only

/// Exposed so `WriteOrderProbe` can vary the order. Nothing else should: the
/// choreography belongs in `setFrame`, and a second caller choosing its own
/// order is how two code paths start disagreeing about how to move a window.
extension AXWindow: RawFrameWriting {
    public func readAXFrame() -> CGRect? { axFrame() }
    public func writeAXPosition(_ position: CGPoint) {
        writePoint(kAXPositionAttribute, position)
    }

    public func writeAXSize(_ size: CGSize) {
        writeSize(kAXSizeAttribute, size)
    }
}
