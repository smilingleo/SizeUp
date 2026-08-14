import CoreGraphics
import Darwin
import Geometry

/// Identifies a window for the lifetime of that window.
///
/// Deriving a real window ID needs the private `_AXUIElementGetWindow`, so
/// this pairs the process ID with the `AXUIElement`'s CFHash instead.
public struct WindowKey: Hashable, Sendable {
    public let pid: pid_t
    public let elementHash: Int

    public init(pid: pid_t, elementHash: Int) {
        self.pid = pid
        self.elementHash = elementHash
    }
}

/// A movable window. All frames are Cocoa coordinates (bottom-left origin);
/// implementations convert to Accessibility coordinates internally.
public protocol WindowHandle: AnyObject {
    var key: WindowKey { get }
    var bundleIdentifier: String? { get }
    func frame() -> CGRect?
    /// Applies a frame and returns what was actually achieved, which may
    /// differ if the application enforces a minimum or maximum size.
    @discardableResult
    func setFrame(_ cocoaRect: CGRect) -> CGRect?
}

public protocol WindowProviding {
    func focusedWindow() -> WindowHandle?
}

public protocol ScreenProviding {
    var screens: [ScreenInfo] { get }
    /// Frame of the display carrying the menu bar — the Accessibility origin.
    var primaryFrame: CGRect { get }
}
