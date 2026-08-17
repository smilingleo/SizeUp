import ApplicationServices
import CoreGraphics
import Foundation

/// The bridge from what `WindowKit` already has (an `AXUIElement`) to what
/// SkyLight wants (a `CGWindowID`), via `_AXUIElementGetWindow`.
///
/// This is a separate resolver from `SkyLight`, because it lives in
/// ApplicationServices rather than SkyLight and is a single symbol rather
/// than a family — no reason to route it through the same struct.
public enum WindowIdentifier {
    // _AXUIElementGetWindow(element, &windowID) -> AXError
    // Resolved and called successfully in
    // .superpowers/sdd/2026-08-14-sizeup2-m4/ax.swift against a real focused
    // window's AXUIElement.
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    private static let getWindow: GetWindowFn? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW
        ), let pointer = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(pointer, to: GetWindowFn.self)
    }()

    /// `nil` if the symbol is unavailable or the lookup itself fails — a
    /// destroyed or otherwise invalid `AXUIElement` must not trap here.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var windowID: UInt32 = 0
        guard getWindow(element, &windowID) == .success else { return nil }
        return windowID
    }
}
