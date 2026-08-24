import Annotation
import AppKit
import Capture
import Config
import VideoEdit
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
/// Both capture flows are implemented end-to-end. A request the build does not
/// support resolves to `.notYetAvailable` rather than doing nothing, which is
/// what the capability set is for.
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

    /// Perform one of the capture actions. Non-capture actions are a no-op.
    func perform(_ action: Action) {
        let event: CaptureEvent?
        switch action {
        case .captureScreenshot: event = .screenshotRequested
        case .startRecording: event = .recordRequested
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
        case .beginRecording:
            // Recording starts by picking a region, which is the same overlay
            // the screenshot path uses; the machine routes the confirm.
            Task { await self.runScreenshotCapture() }
        case .startRecordingSession:
            Task { await self.startRecording() }
        case .stopRecording:
            Task { await self.stopRecording() }
        case .dismissAndCopy:
            confirmAndCopy()
        case .dismiss:
            hideOverlay()
        case .notYetAvailable:
            // No capture feature is unimplemented today, so this is unreachable
            // unless a build ships with a capability switched off. It stays an
            // honest alert rather than silence.
            showComingSoon()
        case .refused:
            NSLog("ClipShot: capture ignored — a capture is already in flight")
        case .none:
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

    // MARK: Recording state

    /// Reads the live capture settings (cursor and click-ripple toggles).
    /// Injected so the session does not reach into the settings store, and so
    /// tests can vary them.
    var captureSettings: () -> Config.CaptureSettings = { Config.CaptureSettings() }

    private var recorder: ScreenRecorder?
    private var recordingTimer: Timer?
    private var borderWindow: RecordingBorderWindow?
    /// The post-recording editor, while it is open.
    private var editorWindow: RecordingEditorWindow?

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
        // Flatten while the overlay is still up: the image and the selection
        // are read through it.
        guard let cropped = cropCurrentSelection() else {
            hideOverlay()
            return
        }
        // Then take the overlay down *before* the panel, not after.
        //
        // The overlay sits at the overlay-window level and the toolbar one
        // above it, both far above a normal panel, so a save dialog opened
        // underneath them is invisible and unreachable — the capture looks
        // frozen. The pixels are already flattened by this point, so the
        // overlay has nothing left to contribute.
        hideOverlay()
        // An accessory app is not active, and an inactive app's modal panel
        // opens unfocused behind whatever the user was looking at.
        activateForPanel()
        if let url = presentSavePanel(cropped) {
            NSLog("ClipShot: saved capture to \(url.path)")
        }
    }

    /// Presents the save dialog. A seam so tests can assert the overlay is
    /// already gone by the time the panel would appear, which is not something
    /// a modal panel lets a test observe.
    var presentSavePanel: (CGImage) -> URL? = { FileSaver.save($0, kind: .capture) }

    /// Bring the app forward so a modal panel is focused and frontmost.
    /// Overridden in tests, where activating would steal focus from the runner.
    var activateForPanel: () -> Void = { NSApp.activate() }

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

    /// Test seams for the save-ordering checks: a modal panel cannot be
    /// observed from a test, so the overlay's presence is inspected instead.
    var hasOverlayForTesting: Bool { overlayWindow != nil }

    func installOverlayForTesting(_ window: OverlayWindow) {
        overlayWindow = window
        window.overlayView.delegate = self
        captured = CapturedImage(
            image: CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .makeImage()!,
            scale: 1)
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
        // Selecting a region does not start anything on its own; the selection
        // is read at confirm time.
        //
        // The toolbar appears only once there is a region to annotate: before
        // that there is nothing for a tool to draw on, and a toolbar floating
        // over an empty dimmed screen just gets in the way of the first drag.
        guard let rect, rect.width >= 5, rect.height >= 5 else {
            toolbar?.orderOut(nil)
            return
        }
        // No annotation toolbar when the overlay is being used to frame a
        // recording: there is nothing to annotate, the shapes would not appear
        // in the video, and the toolbar would sit over the region being framed.
        guard machine.mode != .recording else { return }
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

    // MARK: Recording flow

    /// The region has been chosen: swap the overlay for a border and start
    /// rolling frames.
    private func startRecording() async {
        guard let captured, let view = overlayView, let region = view.selection,
              let screen = overlayWindow?.screen ?? NSScreen.main,
              let cgID = Self.cgDisplayID(of: screen)
        else {
            await abandonRecording("no region to record")
            return
        }
        let scale = captured.scale
        // Take the region picker down first. It is a full-screen dimmed window;
        // leaving it up would be recorded over everything.
        hideOverlay()

        let settings = captureSettings()
        let options = ScreenRecorder.Options(
            region: region, scale: scale, displayID: cgID,
            showsCursor: settings.showCursorInRecordings,
            showsClickRipples: settings.showClickRipples)
        let size = options.pixelSize
        guard size.width > 0, size.height > 0 else {
            await abandonRecording("the region rounds to nothing")
            return
        }

        // The border goes up before the recorder starts, so its window ID can be
        // excluded from the very first frame.
        let border = RecordingBorderWindow()
        border.show(around: region, on: screen.frame)
        borderWindow = border

        do {
            let inventory = try await DisplayInventory.current()
            guard let display = inventory.display(matching: cgID) else {
                await abandonRecording("\(cgID) is not in the shareable display set")
                return
            }
            let recorder = try ScreenRecorder(
                options: options, url: Self.temporaryVideoURL(), inventory: inventory)
            try recorder.start(display: display,
                               excluding: [CGWindowID(border.windowNumber)])
            self.recorder = recorder
            startRecordingTimer()
            NSLog("ClipShot: recording \(size.width)x\(size.height) to \(recorder.url?.lastPathComponent ?? "?")")
        } catch {
            await abandonRecording("could not start recording: \(error)")
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / Double(Recording.fps), repeats: true) {
            [weak self] _ in
            // The tick is async (it awaits ScreenCaptureKit), so it is hopped
            // onto the main actor rather than run inside the timer callback.
            Task { @MainActor [weak self] in
                await self?.recorder?.tick()
            }
        }
        // Common modes, so frames keep being captured while a menu is open or a
        // window is being dragged — exactly when a recording matters most.
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    /// Stop, close the file, and offer to save it.
    private func stopRecording() async {
        recordingTimer?.invalidate()
        recordingTimer = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil

        guard let recorder else { return }
        self.recorder = nil
        do {
            guard let url = try await recorder.finish() else {
                NSLog("ClipShot: the recording captured no frames")
                return
            }
            NSLog("ClipShot: recorded \(recorder.framesWritten) frames")
            await openEditor(for: url)
        } catch {
            NSLog("ClipShot: could not finish the recording: \(error)")
        }
    }

    /// Open the finished recording in the editor.
    ///
    /// The editor rather than a bare save dialog, because the recording is a
    /// draft: the useful edits (trim to the interesting part, label what to look
    /// at, hold on a result) are the reason to record at all. If the video cannot
    /// be opened, fall back to the save dialog rather than losing it.
    private func openEditor(for url: URL) async {
        guard editorWindow == nil else {
            NSLog("ClipShot: an editor is already open")
            return
        }
        do {
            let decoder = try await VideoDecoder(url: url)
            guard decoder.totalFrames > 0 else {
                NSLog("ClipShot: the recording has no frames to edit")
                presentRecordingSave(url)
                return
            }
            let edit = RecordingEdit(videoURL: url, totalFrames: decoder.totalFrames,
                                     fps: decoder.fps)
            let window = makeEditorWindow(edit, decoder)
            window.editorDelegate = self
            editorWindow = window
            // The editor is a real window with keyboard focus, unlike the capture
            // overlay, so the app has to come forward for it to be usable.
            activateForPanel()
            window.present()
        } catch {
            NSLog("ClipShot: could not open the recording for editing: \(error)")
            presentRecordingSave(url)
        }
    }

    /// Seam: builds the editor window, so tests can substitute one.
    var makeEditorWindow: (RecordingEdit, VideoDecoder) -> RecordingEditorWindow = {
        RecordingEditorWindow(edit: $0, decoder: $1)
    }

    /// Take the editor down and clean up the temporary recording.
    private func closeEditor(discardingSource url: URL?) {
        editorWindow?.dismiss()
        editorWindow = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// True while the editor is open. Read by tests.
    var hasEditorForTesting: Bool { editorWindow != nil }

    /// Move the finished video out of the temporary directory.
    ///
    /// A save dialog rather than a silent write: the recording took real effort
    /// and the temporary file is deleted, so a cancelled save has to be a
    /// deliberate choice rather than something that can happen by accident.
    private func presentRecordingSave(_ url: URL) {
        activateForPanel()
        if let destination = presentVideoSavePanel(url) {
            NSLog("ClipShot: saved recording to \(destination.path)")
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Seam: the video save dialog, so tests can drive the flow without a modal.
    var presentVideoSavePanel: (URL) -> URL? = { FileSaver.saveVideo($0) }
    /// Asks where to write an export. Distinct from `presentVideoSavePanel`,
    /// which also moves the file it is given.
    var presentVideoExportPanel: () -> URL? = { FileSaver.askForVideoDestination() }

    /// Tear down a recording that could not start, and report why.
    private func abandonRecording(_ reason: String) async {
        NSLog("ClipShot: \(reason)")
        recordingTimer?.invalidate()
        recordingTimer = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        recorder?.cancel()
        recorder = nil
        hideOverlay()
        machine.resetToIdle()
        fireModeChange()
    }

    private static func temporaryVideoURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshot-recording-\(UUID().uuidString).mp4")
    }

    /// True while frames are being written. Read by tests.
    var isRecordingForTesting: Bool { recorder?.isRecording ?? false }

    // MARK: Alerts

    /// Shown when a capture action is not available in this build. Reachable
    /// only if a capability is switched off, which no shipping build does.
    private func showComingSoon() {
        let alert = NSAlert()
        alert.messageText = "Not available in this build"
        alert.informativeText = "That capture feature is not enabled here."
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

// MARK: - The recording editor

extension CaptureSession: RecordingEditorDelegate {
    public func recordingEditor(_ window: RecordingEditorWindow,
                                didRequestExport edit: RecordingEdit,
                                annotationScale: CGSize) {
        // Ask where to put it *before* spending time encoding: cancelling after a
        // long export would throw the work away. Note this only asks -- the
        // recording must stay where it is, because the export reads from it.
        guard let destination = presentVideoExportPanel() else { return }

        let source = edit.videoURL
        let progress = ExportProgressWindow()
        progress.present()

        // The exporter's callback is `@Sendable` and runs off the main actor,
        // while the window must be touched on it. A stream is the channel between
        // them: the continuation is Sendable, so the callback can yield into it
        // without capturing the window at all.
        let (fractions, sink) = AsyncStream<Double>.makeStream()
        let display = Task { @MainActor in
            for await fraction in fractions { progress.update(fraction) }
        }

        Task { @MainActor in
            defer {
                sink.finish()
                display.cancel()
                progress.dismiss()
            }
            do {
                try await VideoExporter.export(
                    edit, to: destination, annotationScale: annotationScale,
                    onProgress: { fraction in
                        sink.yield(fraction)
                        return true
                    })
                NSLog("ClipShot: exported to \(destination.path)")
                self.closeEditor(discardingSource: source)
                self.machine.resetToIdle()
                self.fireModeChange()
            } catch {
                NSLog("ClipShot: the export failed: \(error)")
                self.showExportFailed(error)
            }
        }
    }

    public func recordingEditorDidCancel(_ window: RecordingEditorWindow) {
        let edit = window.currentEdit
        // Only ask if there is something to lose. A confirmation on an untouched
        // recording is just an extra click between the user and the file.
        if edit.hasEdits, !confirmDiscard() { return }

        // The recording itself is still worth keeping even if the edits are not,
        // so offer to save the original rather than deleting it silently.
        let source = edit.videoURL
        closeEditor(discardingSource: nil)
        presentRecordingSave(source)
        machine.resetToIdle()
        fireModeChange()
    }

    /// Seam: the discard confirmation.
    func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard your edits?"
        alert.informativeText =
            "The annotations, freezes and speed changes will be lost. "
            + "You can still save the original recording."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showExportFailed(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "The export failed"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

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
