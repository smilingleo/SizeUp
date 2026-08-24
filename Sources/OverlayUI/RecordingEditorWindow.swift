import Annotation
import AppKit
import Capture
import VideoEdit

/// What the editor window reports back to the app.
@MainActor
public protocol RecordingEditorDelegate: AnyObject {
    /// Export the edit. The window has already validated there is something to
    /// write; the app owns the save dialog and the file.
    func recordingEditor(_ window: RecordingEditorWindow,
                         didRequestExport edit: RecordingEdit,
                         annotationScale: CGSize)
    /// The user closed without exporting.
    func recordingEditorDidCancel(_ window: RecordingEditorWindow)
}

/// The post-recording editor: play it back, annotate over time, freeze, retime,
/// then export.
///
/// A real window rather than the borderless panel the capture overlay uses: this
/// is a document being worked on, so it should be movable, resizable, and behave
/// like an ordinary window. That also means it can take keyboard focus safely,
/// which the capture toolbar deliberately cannot.
public final class RecordingEditorWindow: NSWindow {
    public weak var editorDelegate: RecordingEditorDelegate?

    private let canvas: RecordingCanvasView
    private let timeline = TimelineView()
    /// Named `toolPanel`, not `toolbar`: `NSWindow.toolbar` already exists and
    /// shadowing it fails to compile in a way that points at the wrong line.
    private let toolPanel = ToolbarWindow()

    // Controls.
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let speedPopUp = NSPopUpButton()
    private let freezeButton = NSButton()
    private let pulseButton = NSButton()
    private let exportButton = NSButton()

    private var playbackTimer: Timer?

    /// Matching the Rust editor's options.
    static let speedOptions: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// How long a freeze inserted from the button lasts.
    static let insertedHoldSeconds: Double = 2

    /// The document as it stands. Read by the app when exporting or closing.
    public var currentEdit: RecordingEdit { canvas.bridge.edit }

    private var bridge: EditorBridge {
        get { canvas.bridge }
        set { canvas.bridge = newValue }
    }

    public init(edit: RecordingEdit, decoder: VideoDecoder) {
        canvas = RecordingCanvasView(bridge: EditorBridge(edit: edit))
        // Size the window to the video, capped to the screen: a 4K recording
        // would otherwise open larger than the display it was taken on.
        let videoSize = decoder.pixelSize
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let maxCanvas = CGSize(width: available.width * 0.8,
                              height: available.height * 0.8 - Self.chromeHeight)
        let scale = min(1, min(maxCanvas.width / max(videoSize.width, 1),
                              maxCanvas.height / max(videoSize.height, 1)))
        let canvasSize = CGSize(width: max(videoSize.width * scale, 480),
                                height: max(videoSize.height * scale, 270))

        super.init(
            contentRect: CGRect(origin: .zero,
                                size: CGSize(width: canvasSize.width,
                                             height: canvasSize.height + Self.chromeHeight)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)

        canvas.decoder = decoder
        canvas.canvasDelegate = self
        title = "Recording — \(edit.videoURL.lastPathComponent)"
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        delegate = self

        buildContent()
        center()
        refresh()
    }

    static let controlsHeight: CGFloat = 36
    static var chromeHeight: CGFloat { TimelineView.totalHeight + controlsHeight }

    // MARK: Layout

    private func buildContent() {
        let root = NSView(frame: CGRect(origin: .zero, size: contentRect(forFrameRect: frame).size))
        root.autoresizingMask = [.width, .height]

        canvas.autoresizingMask = [.width, .height]
        timeline.autoresizingMask = [.width, .minYMargin]
        timeline.timelineDelegate = self

        let controls = buildControls()
        controls.autoresizingMask = [.width, .minYMargin]

        root.addSubview(canvas)
        root.addSubview(timeline)
        root.addSubview(controls)
        contentView = root
        layoutParts()
    }

    private func layoutParts() {
        guard let root = contentView else { return }
        let height = root.bounds.height
        let controlsY = height - Self.controlsHeight
        let timelineY = controlsY - TimelineView.totalHeight

        // AppKit's origin is bottom-left, so the canvas fills what is left below
        // the chrome.
        root.subviews.first { $0 === canvas }?.frame =
            CGRect(x: 0, y: 0, width: root.bounds.width, height: timelineY)
        timeline.frame = CGRect(x: 0, y: timelineY,
                                width: root.bounds.width, height: TimelineView.totalHeight)
        root.subviews.last?.frame = CGRect(x: 0, y: controlsY,
                                           width: root.bounds.width,
                                           height: Self.controlsHeight)
    }

    private func buildControls() -> NSView {
        let bar = NSView()

        configure(playButton, symbol: "play.fill", fallback: "▶", action: #selector(togglePlay))
        configure(freezeButton, symbol: "snowflake", fallback: "❄", action: #selector(insertFreeze))
        freezeButton.toolTip = "Freeze this frame for \(Int(Self.insertedHoldSeconds))s (F)"
        configure(pulseButton, symbol: "waveform.circle", fallback: "◎",
                  action: #selector(togglePulse))
        pulseButton.toolTip = "Pulse the selected annotation (U)"

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        speedPopUp.addItems(withTitles: Self.speedOptions.map { Self.speedTitle($0) })
        speedPopUp.selectItem(at: Self.speedOptions.firstIndex(of: 1) ?? 2)
        speedPopUp.target = self
        speedPopUp.action = #selector(changeSpeed)
        speedPopUp.toolTip = "Playback speed"

        exportButton.title = "Export…"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(export)
        exportButton.keyEquivalent = "\r"

        for view in [playButton, freezeButton, pulseButton, timeLabel,
                     speedPopUp, exportButton] as [NSView] {
            bar.addSubview(view)
        }
        bar.postsFrameChangedNotifications = true

        // Laid out by hand in `layoutControls`, called from the frame observer:
        // six controls in a row does not justify a constraint graph, and manual
        // frames keep the sizes identical to the capture toolbar's.
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: bar, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutControls(in: bar) }
        }
        layoutControls(in: bar)
        return bar
    }

    private func layoutControls(in bar: NSView) {
        let pad: CGFloat = 8
        let gap: CGFloat = 6
        let buttonSize = CGSize(width: 30, height: 22)
        let y = (bar.bounds.height - buttonSize.height) / 2

        var x = pad
        for button in [playButton, freezeButton, pulseButton] {
            button.frame = CGRect(origin: CGPoint(x: x, y: y), size: buttonSize)
            x += buttonSize.width + gap
        }
        timeLabel.frame = CGRect(x: x + gap, y: y + 3, width: 116, height: 16)

        let exportWidth: CGFloat = 88
        let speedWidth: CGFloat = 78
        exportButton.frame = CGRect(x: bar.bounds.width - pad - exportWidth, y: y - 1,
                                    width: exportWidth, height: buttonSize.height + 2)
        speedPopUp.frame = CGRect(x: exportButton.frame.minX - gap - speedWidth, y: y - 2,
                                  width: speedWidth, height: buttonSize.height + 4)
    }

    private func configure(_ button: NSButton, symbol: String, fallback: String,
                           action: Selector) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
        } else {
            button.title = fallback
        }
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
    }

    private static func speedTitle(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
    }

    // MARK: Presenting

    public func present() {
        // The toolbar is the same one the capture overlay uses, so the drawing
        // tools behave identically in both editors.
        toolPanel.toolbarDelegate = self
        toolPanel.sync(with: bridge.editor)
        makeKeyAndOrderFront(nil)
        positionToolbar()
        toolPanel.orderFront(nil)
        makeFirstResponder(canvas)
        startFrameObservation()
    }

    private func positionToolbar() {
        guard let screen = screen ?? NSScreen.main else { return }
        // Above the window's top edge, clamped onto the screen.
        let origin = CGPoint(
            x: frame.midX - toolPanel.frame.width / 2,
            y: min(frame.maxY + 8,
                   screen.visibleFrame.maxY - toolPanel.frame.height - 4))
        toolPanel.setFrameOrigin(origin)
    }

    private func startFrameObservation() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layoutParts()
                self?.positionToolbar()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionToolbar() }
        }
    }

    public func dismiss() {
        stopPlayback()
        toolPanel.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
        orderOut(nil)
    }

    // MARK: Playback

    @objc private func togglePlay() {
        bridge.isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        canvas.endTextEditing()
        // From the beginning if it is already at the end, so the button always
        // does something rather than appearing dead.
        if bridge.currentFrame >= bridge.edit.totalFrames - 1 {
            bridge.seek(to: 0)
        }
        bridge.isPlaying = true
        // Real time, not source time: the interval is the *output* frame rate, so
        // a speed change is already accounted for by the shorter timeline.
        let timer = Timer(timeInterval: 1 / bridge.edit.fps, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.bridge.advance() { self.stopPlayback() }
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
        refresh()
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        bridge.isPlaying = false
        refresh()
    }

    // MARK: Actions

    @objc private func insertFreeze() {
        let hold = max(Int((bridge.edit.fps * Self.insertedHoldSeconds).rounded()), 1)
        bridge.insertFreeze(at: bridge.currentFrame, holdFrames: hold)
        canvas.invalidateFrame()
        refresh()
    }

    @objc private func togglePulse() {
        bridge.toggleSelectedPulse()
        refresh()
    }

    @objc private func changeSpeed() {
        let index = speedPopUp.indexOfSelectedItem
        guard Self.speedOptions.indices.contains(index) else { return }
        stopPlayback()
        bridge.setPlaybackSpeed(Self.speedOptions[index])
        canvas.invalidateFrame()
        refresh()
    }

    @objc private func export() {
        canvas.endTextEditing()
        stopPlayback()
        editorDelegate?.recordingEditor(self, didRequestExport: bridge.edit,
                                        annotationScale: canvas.annotationSpace)
    }

    // MARK: Refresh

    private func refresh() {
        timeline.edit = bridge.edit
        timeline.selectedIndex = bridge.selectedDocumentIndex
        canvas.needsDisplay = true
        toolPanel.sync(with: bridge.editor)

        let symbol = bridge.isPlaying ? "pause.fill" : "play.fill"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            playButton.image = image
        } else {
            playButton.title = bridge.isPlaying ? "❚❚" : "▶"
        }
        pulseButton.isEnabled = bridge.selectedDocumentIndex != nil
        timeLabel.stringValue =
            "\(Self.timecode(bridge.currentFrame, fps: bridge.edit.fps))"
            + " / \(Self.timecode(bridge.edit.totalFrames, fps: bridge.edit.fps))"
    }

    /// `m:ss` — the recordings this edits are short, so hours would be noise.
    static func timecode(_ frame: Int, fps: Double) -> String {
        let seconds = Double(frame) / max(fps, 1)
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        guard !canvas.isEditingText else { super.keyDown(with: event); return }

        // Space is play/pause, which no drawing tool may claim.
        if event.keyCode == 49 {
            togglePlay()
            return
        }
        switch event.keyCode {
        case 53: // Escape
            if bridge.editor.selected != nil {
                bridge.editor.clearSelection()
                bridge.sync()
                refresh()
            } else {
                editorDelegate?.recordingEditorDidCancel(self)
            }
            return
        case 51, 117: // Delete
            bridge.deleteSelected()
            refresh()
            return
        case 123: // Left
            step(by: event.modifierFlags.contains(.shift) ? -10 : -1)
            return
        case 124: // Right
            step(by: event.modifierFlags.contains(.shift) ? 10 : 1)
            return
        default:
            break
        }

        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            event.modifierFlags.contains(.shift) ? bridge.redo() : bridge.undo()
            canvas.invalidateFrame()
            refresh()
            return
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": insertFreeze(); return
        case "u": togglePulse(); return
        default: break
        }

        // Anything else goes to the shared tool shortcuts.
        if let key = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.shortcutKey == key }) {
            bridge.editor.select(tool: tool)
            refresh()
            return
        }
        super.keyDown(with: event)
    }

    private func step(by delta: Int) {
        stopPlayback()
        bridge.seek(to: bridge.currentFrame + delta)
        refresh()
    }
}

// MARK: - Delegates

extension RecordingEditorWindow: RecordingCanvasDelegate {
    public func canvasDidEdit(_ canvas: RecordingCanvasView) {
        refresh()
    }
}

extension RecordingEditorWindow: TimelineDelegate {
    public func timelineDidScrub(to frame: Int) {
        stopPlayback()
        bridge.seek(to: frame)
        refresh()
    }

    public func timelineDidSelect(annotation index: Int) {
        stopPlayback()
        bridge.selectDocument(index, seekIntoRange: true)
        canvas.invalidateFrame()
        refresh()
    }

    public func timelineDidRetime(annotation index: Int, start: Int, end: Int?) {
        bridge.selectDocument(index)
        bridge.setSelectedRange(start: start, end: end)
        refresh()
    }
}

extension RecordingEditorWindow: ToolbarDelegate {
    public func toolbar(_ toolbar: ToolbarWindow, didSelect tool: Tool) {
        canvas.endTextEditing()
        bridge.editor.select(tool: tool)
        refresh()
    }

    public func toolbar(_ toolbar: ToolbarWindow, didPick color: AnnotationColor) {
        bridge.editor.style.color = color
        bridge.editor.applyStyleToSelection()
        bridge.sync()
        refresh()
    }

    public func toolbar(_ toolbar: ToolbarWindow, didPickStroke width: CGFloat) {
        bridge.editor.style.width = width
        bridge.editor.applyStyleToSelection()
        bridge.sync()
        refresh()
    }

    public func toolbar(_ toolbar: ToolbarWindow, didPickFontSize size: CGFloat) {
        bridge.editor.style.fontSize = size
        bridge.editor.applyStyleToSelection()
        bridge.sync()
        refresh()
    }

    public func toolbarDidUndo(_ toolbar: ToolbarWindow) {
        bridge.undo()
        canvas.invalidateFrame()
        refresh()
    }

    public func toolbarDidRedo(_ toolbar: ToolbarWindow) {
        bridge.redo()
        canvas.invalidateFrame()
        refresh()
    }

    public func toolbarDidCancel(_ toolbar: ToolbarWindow) {
        editorDelegate?.recordingEditorDidCancel(self)
    }

    /// Save and confirm both mean export here: there is one output, and the
    /// distinction the capture overlay draws (clipboard versus file) has no
    /// meaning for a video.
    public func toolbarDidSave(_ toolbar: ToolbarWindow) {
        export()
    }

    public func toolbarDidConfirm(_ toolbar: ToolbarWindow) {
        export()
    }
}

extension RecordingEditorWindow: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        editorDelegate?.recordingEditorDidCancel(self)
        // The delegate decides, since it may want to confirm discarding edits.
        return false
    }
}
