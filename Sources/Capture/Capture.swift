import CoreGraphics

// The `Capture` target: ScreenCaptureKit display capture, display lookup, and
// the Screen Recording permission. AppKit-free on purpose (layering lint): it
// must be testable without a window on screen and must not import the
// window-manager modules. `ScreenCaptureKit` and `CoreGraphics` are public
// API — the private-API quarantine in `SpaceKit` is untouched by the capture
// merge. See `Permission`, `Display`, `Inventory`, and `Screenshot`.
