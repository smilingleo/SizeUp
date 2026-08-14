import CoreGraphics
import Geometry
import WindowKit
@testable import Core

// Shared by ActionRouterTests and ActionRouterDisplayTests. These previously
// existed as two same-named `private` copies in one target, which had already
// diverged: one echoed the requested frame while the other simulated a minimum
// window size. Two fakes with one name and different behaviour is a trap, so
// there is now exactly one, keeping the min-size-simulating version because it
// is the one that models a real application.

let builtIn = ScreenInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
    visibleFrame: CGRect(x: 0, y: 0, width: 3360, height: 1860)
)

/// The real external display: mounted higher, so its Cocoa origin Y is negative.
let external = ScreenInfo(
    id: 2,
    frame: CGRect(x: 3360, y: -838, width: 2056, height: 1329),
    visibleFrame: CGRect(x: 3360, y: -838, width: 2056, height: 1291)
)

final class TestWindow: WindowHandle {
    let key: WindowKey
    var bundleIdentifier: String?
    var stored: CGRect
    var minSize: CGSize
    private(set) var applied: [CGRect] = []

    init(key: WindowKey = WindowKey(pid: 1, elementHash: 1),
         frame: CGRect,
         bundleIdentifier: String? = "com.example.app",
         minSize: CGSize = .zero) {
        self.key = key
        self.stored = frame
        self.bundleIdentifier = bundleIdentifier
        self.minSize = minSize
    }

    func frame() -> CGRect? { stored }

    @discardableResult
    func setFrame(_ cocoaRect: CGRect) -> CGRect? {
        // Mirrors AXWindow.setFrame's guard, so router-level tests can pin the
        // milestone's only real safety mechanism instead of trusting the
        // predicate's unit test and eyeballing the call site.
        guard cocoaRect.isSafeToApply else { return nil }
        applied.append(cocoaRect)
        stored = CGRect(
            origin: cocoaRect.origin,
            size: CGSize(width: max(cocoaRect.width, minSize.width),
                         height: max(cocoaRect.height, minSize.height))
        )
        return stored
    }
}

struct TestScreens: ScreenProviding {
    var screens: [ScreenInfo]
    var primaryFrame: CGRect { screens[0].frame }
}

struct TestWindows: WindowProviding {
    var window: WindowHandle?
    /// Counts lookups so tests can prove the router queried but did not act.
    final class Counter { var lookups = 0 }
    let counter = Counter()
    func focusedWindow() -> WindowHandle? {
        counter.lookups += 1
        return window
    }
}

@MainActor
func makeRouter(
    window: WindowHandle?,
    screens: [ScreenInfo] = [builtIn],
    spans: [Span] = [.half],
    skipList: Set<String> = [],
    store: WindowStateStore = WindowStateStore()
) -> ActionRouter {
    ActionRouter(
        screens: TestScreens(screens: screens),
        windows: TestWindows(window: window),
        store: store,
        gaps: .zero,
        spans: spans,
        skipList: skipList
    )
}

