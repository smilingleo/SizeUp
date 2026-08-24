import Testing
import CoreGraphics
import Geometry
@testable import WindowKit

/// A window that clamps to a minimum size, like Xcode does.
final class FakeWindow: WindowHandle {
    let key = WindowKey(pid: 42, elementHash: 1)
    var bundleIdentifier: String? = "com.example.fake"
    var stored: CGRect
    var minSize: CGSize
    var setFrameCallCount = 0

    init(frame: CGRect, minSize: CGSize = .zero) {
        self.stored = frame
        self.minSize = minSize
    }

    func frame() -> CGRect? { stored }

    @discardableResult
    func setFrame(_ cocoaRect: CGRect) -> CGRect? {
        setFrameCallCount += 1
        stored = CGRect(
            origin: cocoaRect.origin,
            size: CGSize(
                width: max(cocoaRect.width, minSize.width),
                height: max(cocoaRect.height, minSize.height)
            )
        )
        return stored
    }
}

@Test func fakeWindowReportsAchievedFrameNotRequested() {
    let w = FakeWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                       minSize: CGSize(width: 1000, height: 400))
    let achieved = w.setFrame(CGRect(x: 0, y: 0, width: 500, height: 500))
    #expect(achieved == CGRect(x: 0, y: 0, width: 1000, height: 500))
    #expect(w.frame() == achieved)
}

@Test func windowKeysDistinguishWindowsAcrossProcesses() {
    let a = WindowKey(pid: 1, elementHash: 100)
    let b = WindowKey(pid: 2, elementHash: 100)
    let c = WindowKey(pid: 1, elementHash: 100)
    #expect(a != b)
    #expect(a == c)
    #expect(Set([a, b, c]).count == 2)
}
