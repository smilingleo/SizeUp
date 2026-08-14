import CoreGraphics

/// A display, described in Cocoa coordinates (bottom-left origin).
///
/// `visibleFrame` excludes the menu bar and Dock. All placement math uses it.
public struct ScreenInfo: Sendable, Equatable, Identifiable {
    public let id: Int
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: Int, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Displays in a stable spatial order: left to right, then bottom to top.
///
/// `NSScreen.screens` order is not spatial and not stable, so "next display"
/// must not be built on it. Sorting by position means the sequence a user
/// steps through matches the physical arrangement in front of them.
public func spatiallyOrdered(_ screens: [ScreenInfo]) -> [ScreenInfo] {
    screens.sorted { a, b in
        if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
        if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
        return a.id < b.id
    }
}
