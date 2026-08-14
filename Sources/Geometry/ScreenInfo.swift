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
