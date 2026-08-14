import AppKit
import ApplicationServices
import Geometry

public struct AXWindowProvider: WindowProviding {
    private let screens: ScreenProviding

    public init(screens: ScreenProviding) {
        self.screens = screens
    }

    public func focusedWindow() -> WindowHandle? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &raw
        ) == .success, let rawElement = raw, CFGetTypeID(rawElement) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(rawElement, to: AXUIElement.self)

        return AXWindow(
            element: element,
            pid: app.processIdentifier,
            primaryFrame: screens.primaryFrame,
            bundleIdentifier: app.bundleIdentifier
        )
    }
}

public struct SystemScreenProvider: ScreenProviding {
    public init() {}

    public var screens: [ScreenInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            ScreenInfo(id: index, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    public var primaryFrame: CGRect {
        NSScreen.screens.first?.frame ?? .zero
    }
}
