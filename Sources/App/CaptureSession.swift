import Annotation
import AppKit
import Capture
import Core
import Geometry
import OverlayUI

/// The App-side capture orchestrator.
///
/// This is the `App` half of the design's `CaptureSession`: it owns the overlay
/// and runs the async capture, while the *decisions* (which mode an event
/// produces, and what is excluded in which mode) live in `Core`'s
/// `CaptureStateMachine`. Splitting it that way is deliberate — `App` is an
/// executable target that SPM cannot import from a test target, so the machine
/// (the logic worth testing) is in `Core`, and this class is the thin AppKit
/// shell around it (exercised by the manual checklist, not unit tests).
///
/// C1 implements the screenshot flow end-to-end. With `capabilities ==
/// .screenshot`, the machine makes `.record`/`.scroll` requests resolve to
/// `.notYetAvailable` — the honest "coming in a later build" alert — and only
/// `.capturing` is reachable, so the recording/scroll arms here are the stubs
/// the design specifies for C1, not dead code.
@MainActor
final class CaptureSession: OverlayViewDelegate {
    private var machine: CaptureStateMachine

    /// The session mode, read straight from the machine. `App` derives the
    /// status icon and menu from this.
    var mode: CaptureMode { machine.mode }

    private var overlayWindow: OverlayWindow?
    private var captured: CapturedImage?

    /// The overlay view, once presented. The delegate callbacks and the confirm
    /// path read the selection through this.
    private var overlayView: OverlayView? { overlayWindow?.overlayView }

    // One-per-lifecycle flags: the system prompt fires once (macOS also limits
    // it), and the "open System Settings" alert is one-time per the design.
    private var hasRequestedScreenRecording = false
    private var hasShownScreenRecordingAlert = false

    /// Called on the main actor after any mode change, so `App` can refresh
    /// the status icon and menu. Wired in `AppDelegate`; `nil` in tests.
    var modeDidChange: ((CaptureMode) -> Void)?

    init(capabilities: CaptureCapabilities = .screenshot) {
        self.machine = CaptureStateMachine(capabilities: capabilities)
    }

    /// Notify the delegate of the current mode. Over-calling is harmless: the
    /// delegate's refresh is idempotent.
    private func fireModeChange() {
        modeDidChange?(machine.mode)
    }

    // MARK: Dispatch (hotkey and menu both route here)

    /// Perform one of the three capture actions. Non-capture actions are a no-op.
    func perform(_ action: Action) {
        let event: CaptureEvent?
        switch action {
        case .captureScreenshot: event = .screenshotRequested
        case .startRecording: event = .recordRequested
        case .toggleScrollCapture: event = .scrollRequested
        // The fifteen window actions never reach this method — `App` routes
        // them to the window router. Named (not `default`) so a new `Action`
        // case fails to compile here rather than being silently dropped.
        case .half, .quarter, .center, .fullScreen, .snapBack, .display, .space:
            event = nil
        }
        guard let event else { return }

        let effect = machine.handle(event)
        NSLog("ClipShot: capture \(effect) for \(event) -> \(machine.mode)")
        perform(effect)
        fireModeChange()
    }

    private func perform(_ effect: CaptureEffect) {
        switch effect {
        case .beginCapture:
            Task { await self.runScreenshotCapture() }
        case .dismissAndCopy:
            confirmAndCopy()
        case .dismiss:
            hideOverlay()
        case .notYetAvailable:
            showComingSoon()
        case .refused:
            NSLog("ClipShot: capture ignored — a capture is already in flight")
        case .beginRecording, .beginScrollCapture, .stopRecording, .none:
            // Unreachable in C1 (recording/scroll are not enabled).
            break
        }
    }

    // MARK: Screenshot flow

    private func runScreenshotCapture() async {
        guard guardScreenRecordingPermission() else {
            machine.resetToIdle()
            fireModeChange()
            return
        }

        guard let screen = Self.screenUnderCursor(),
              let cgID = Self.cgDisplayID(of: screen)
        else {
            NSLog("ClipShot: could not determine the display under the cursor")
            machine.resetToIdle()
            fireModeChange()
            return
        }

        do {
            let inventory = try await DisplayInventory.current()
            guard let scDisplay = inventory.display(matching: cgID) else {
                NSLog("ClipShot: \(cgID) not in the shareable display set")
                machine.resetToIdle()
                fireModeChange()
                return
            }
            let scale = screen.backingScaleFactor
            let pixelSize = CGSize(
                width: Screenshot.even(Int((screen.frame.width * scale).rounded())),
                height: Screenshot.even(Int((screen.frame.height * scale).rounded()))
            )
            guard pixelSize.width > 0, pixelSize.height > 0 else {
                machine.resetToIdle()
                fireModeChange()
                return
            }
            guard let image = await Screenshot.capture(
                inventory, display: scDisplay, pixelSize: pixelSize, showsCursor: true
            ) else {
                NSLog("ClipShot: ScreenCaptureKit returned no image")
                machine.resetToIdle()
                fireModeChange()
                return
            }
            self.captured = CapturedImage(image: image, scale: scale)
            presentOverlay(on: screen)
        } catch {
            NSLog("ClipShot: capture failed: \(error.localizedDescription)")
            machine.resetToIdle()
            fireModeChange()
        }
    }

    /// Screen Recording is gated at dispatch, never at launch, and independent
    /// of Accessibility (the design: the two never cross-gate).
    private func guardScreenRecordingPermission() -> Bool {
        if ScreenCapturePermission.hasAccess { return true }
        if !hasRequestedScreenRecording {
            hasRequestedScreenRecording = true
            ScreenCapturePermission.requestAccess()
        } else if !hasShownScreenRecordingAlert {
            hasShownScreenRecordingAlert = true
            showScreenRecordingAlert()
        }
        // `CGRequestScreenCaptureAccess` grants asynchronously, so even right
        // after prompting, access is not yet held: this attempt aborts.
        return false
    }

    /// The editor toolbar, shown once a region exists.
    private var toolbar: ToolbarWindow?

    private func presentOverlay(on screen: NSScreen) {
        guard let captured else { return }
        if overlayWindow == nil {
            overlayWindow = OverlayWindow(displayFrame: screen.frame, scale: captured.scale)
        }
        overlayWindow?.setFrame(screen.frame, display: true)
        overlayWindow?.overlayView.delegate = self
        // The image is sized in *points* (the display's frame) so the flipped
        // view's `draw(in: bounds)` fills 1:1; the cgImage's pixels supply the
        // scale-factor sharpness. This mirrors the Rust overlay.
        let nsImage = NSImage(cgImage: captured.image, size: screen.frame.size)
        overlayWindow?.overlayView.setScreenshot(nsImage, scale: captured.scale)
        overlayWindow?.present()
    }

    private func confirmAndCopy() {
        defer { hideOverlay() }
        guard let cropped = cropCurrentSelection() else { return }
        Clipboard.copy(cropped)
    }

    private func save() {
        defer { hideOverlay() }
        guard let cropped = cropCurrentSelection() else { return }
        if let url = FileSaver.save(cropped, kind: .capture) {
            NSLog("ClipShot: saved capture to \(url.path)")
        }
    }

    /// The confirmed selection cropped out of the capture, in pixels. `nil` when
    /// there is no capture/selection or the selection is too small.
    private func cropCurrentSelection() -> CGImage? {
        guard let captured, let view = overlayView, let selection = view.selection else { return nil }
        // Any text still being typed counts as drawn — the user pressing Return
        // to confirm should not lose the label they just typed.
        view.endTextEditing()
        guard let flattened = Compositor.flatten(
            captured.image, selection: selection, scale: captured.scale,
            annotations: view.annotations
        ) else {
            NSLog("ClipShot: selection produced an empty crop")
            return nil
        }
        return flattened
    }

    private func hideOverlay() {
        toolbar?.orderOut(nil)
        toolbar = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        captured = nil
    }

    // MARK: OverlayViewDelegate

    public func overlayView(_ view: OverlayView, didChangeSelection rect: CGRect?) {
        // C1 has no auto-start on selection (that is the recording/scroll
        // behavior, C3/C5). The selection is read at confirm time.
        //
        // The toolbar appears only once there is a region to annotate: before
        // that there is nothing for a tool to draw on, and a toolbar floating
        // over an empty dimmed screen just gets in the way of the first drag.
        guard let rect, rect.width >= 5, rect.height >= 5 else {
            toolbar?.orderOut(nil)
            return
        }
        showToolbar(near: rect, view: view)
    }

    private func showToolbar(near rect: CGRect, view: OverlayView) {
        if toolbar == nil {
            let panel = ToolbarWindow()
            panel.toolbarDelegate = self
            toolbar = panel
        }
        guard let toolbar, let screen = overlayWindow?.screen ?? NSScreen.main else { return }
        toolbar.sync(with: view.editor)
        toolbar.position(near: rect, on: screen.frame, viewHeight: view.bounds.height)
        // `orderFront`, never `makeKey`: the overlay has to keep first
        // responder or the one-key tool shortcuts and Escape stop working.
        toolbar.orderFront(nil)
    }

    public func overlayViewDidChangeEditor(_ view: OverlayView) {
        toolbar?.sync(with: view.editor)
    }

    public func overlayViewDidConfirm(_ view: OverlayView) {
        let effect = machine.handle(.overlayConfirmed)
        perform(effect)
        fireModeChange()
    }

    public func overlayViewDidSave(_ view: OverlayView) {
        save()
    }

    public func overlayViewDidDismiss(_ view: OverlayView) {
        let effect = machine.handle(.overlayCancelled)
        perform(effect)
        fireModeChange()
    }

    // MARK: Alerts

    /// The one-time "coming in a later build" notice for record/scroll in C1.
    private func showComingSoon() {
        let alert = NSAlert()
        alert.messageText = "Coming in a later build"
        alert.informativeText =
            "Screen recording and scroll capture land in an upcoming ClipShot build. "
            + "The shortcut stays registered; screenshot works today."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showScreenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText =
            "ClipShot needs Screen Recording access to capture the screen. "
            + "Grant it in System Settings, then try again. "
            + "Capture never leaves this Mac."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Display lookup (AppKit — the App layer may use NSScreen)

    /// The `NSScreen` the cursor is on, or the main screen if on none (a session
    /// with no mouse). AppKit's own cursor reader, kept here because `App` is
    /// the one AppKit-allowed layer.
    static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    /// The CoreGraphics display ID of an `NSScreen`, via the long-standing
    /// `NSScreenNumber` device key. This is the bridge from the AppKit screen
    /// (used for the overlay window frame + scale) to the `SCDisplay`
    /// (used for the ScreenCaptureKit capture).
    static func cgDisplayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let raw = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return raw.uint32Value
    }
}

// MARK: - ToolbarDelegate

extension CaptureSession: ToolbarDelegate {
    public func toolbar(_ toolbar: ToolbarWindow, didSelect tool: Tool) {
        overlayView?.editor.select(tool: tool)
        refreshToolbar()
    }

    public func toolbar(_ toolbar: ToolbarWindow, didPick color: AnnotationColor) {
        overlayView?.editor.style.color = color
        // Applying to the selection is what makes a swatch a restyle rather
        // than only a setting for the next shape.
        overlayView?.editor.applyStyleToSelection()
        refreshToolbar()
    }

    public func toolbar(_ toolbar: ToolbarWindow, didPickStroke width: CGFloat) {
        overlayView?.editor.style.width = width
        overlayView?.editor.applyStyleToSelection()
        refreshToolbar()
    }

    public func toolbar(_ toolbar: ToolbarWindow, didPickFontSize size: CGFloat) {
        overlayView?.editor.style.fontSize = size
        overlayView?.editor.applyStyleToSelection()
        refreshToolbar()
    }

    public func toolbarDidUndo(_ toolbar: ToolbarWindow) {
        overlayView?.editor.undo()
        refreshToolbar()
    }

    public func toolbarDidRedo(_ toolbar: ToolbarWindow) {
        overlayView?.editor.redo()
        refreshToolbar()
    }

    public func toolbarDidCancel(_ toolbar: ToolbarWindow) {
        guard let view = overlayView else { return }
        overlayViewDidDismiss(view)
    }

    public func toolbarDidSave(_ toolbar: ToolbarWindow) {
        save()
    }

    public func toolbarDidConfirm(_ toolbar: ToolbarWindow) {
        guard let view = overlayView else { return }
        overlayViewDidConfirm(view)
    }

    /// Redraw the canvas and put the controls back in step with it.
    private func refreshToolbar() {
        guard let view = overlayView else { return }
        view.needsDisplay = true
        toolbar?.sync(with: view.editor)
    }
}
