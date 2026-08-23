/// The capture session's mode — the merged app's analog of ClipShot's
/// `app.rs` mode flags, made explicit rather than scattered booleans.
///
/// (The design placed this state machine in `App`; because `App` is an
/// executable target that SPM cannot import from a test target, the *pure*
/// machine lives here in `Core` — its charter is exactly this: routing/decision
/// logic, no AppKit, fully testable with fakes. `App` hosts the AppKit
/// orchestrator that drives an instance of this machine. See the C1 plan.)
public enum CaptureMode: Equatable, Sendable {
    case idle
    case capturing
    case recording
    case scrollCapturing
    case editing
}

/// A request or lifecycle event the session can react to.
///
/// Kept free of the `Action` type on purpose: the machine is pure and
/// milestone-independent, and `App` maps the three capture `Action`s onto the
/// three `*Requested` events. That keeps the transition table from knowing it
/// has a keymap.
public enum CaptureEvent: Equatable, Sendable {
    case screenshotRequested
    case recordRequested
    case scrollRequested
    case overlayConfirmed
    case overlayCancelled
    case recordingStopped
    case editorOpened
    case editorClosed
}

/// What the caller must do when a transition fires. The machine decides *what*
/// happens; `App` decides *how* (it owns the overlay, the capture, the
/// clipboard, and the save panel).
public enum CaptureEffect: Equatable, Sendable {
    /// Show the region-selection overlay (screenshot mode).
    case beginCapture
    /// Show the overlay in record mode; recording starts on confirm. (C3)
    case beginRecording
    /// Show the overlay in scroll-capture mode. (C5)
    case beginScrollCapture
    /// Hide the overlay and copy the crop to the clipboard. (C1)
    case dismissAndCopy
    /// Hide the overlay with no side effect (the user cancelled).
    case dismiss
    /// Stop the recording. (C3)
    case stopRecording
    /// The request names a feature this build does not implement yet; stay put.
    case notYetAvailable
    /// The request is excluded by the current mode; stay put.
    case refused
    /// Nothing to do.
    case none
}

/// Which capture features this build implements.
///
/// The machine is written for the full C1–C5 feature set; the capability set
/// is what makes a milestone's behavior fall out of it. C1 is `.screenshot`
/// alone, so `record`/`scroll` requests resolve to `.notYetAvailable` (the
/// honest "coming in a later build" alert in `App`) and only `.capturing` is
/// reachable. C3 adds `.recording`, C5 adds `.scrollCapture` — no change to the
/// transition table, only the set.
public struct CaptureCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let screenshot = CaptureCapabilities(rawValue: 1 << 0)
    public static let recording = CaptureCapabilities(rawValue: 1 << 1)
    public static let scrollCapture = CaptureCapabilities(rawValue: 1 << 2)
    public static let editing = CaptureCapabilities(rawValue: 1 << 3)
}

/// The capture session's state machine: one pure function of `(mode, event,
/// capabilities)`.
///
/// Every mode is a `case` and every event in every mode is named, so a new
/// mode or event fails to compile instead of silently getting `default`'d into
/// the wrong behavior. The exclusion rules the design calls out are explicit
/// arms, not comments: no screenshot while recording/editing/scroll-capturing,
/// no recording while editing.
public struct CaptureStateMachine: Equatable, Sendable {
    public private(set) var mode: CaptureMode
    public let capabilities: CaptureCapabilities

    public init(
        mode: CaptureMode = .idle,
        capabilities: CaptureCapabilities = .screenshot
    ) {
        self.mode = mode
        self.capabilities = capabilities
    }

    /// Apply `event`, moving to the resulting mode.
    ///
    /// Returns the effect `App` must perform. Idempotently safe: an event that
    /// the current mode does not act on returns `.none` and leaves `mode`
    /// unchanged, so dispatching a stale or double event is a no-op rather than
    /// a fault.
    @discardableResult
    public mutating func handle(_ event: CaptureEvent) -> CaptureEffect {
        let (next, effect) = Self.transition(from: mode, on: event, in: capabilities)
        mode = next
        return effect
    }

    /// Return to `.idle` without running the event table.
    ///
    /// Used by `App` when a capture *attempt* fails after the mode already
    /// advanced to `.capturing` (no permission, no display, ScreenCaptureKit
    /// returned nothing). Those failures are the orchestrator's to detect — the
    /// machine cannot know the capture pipeline failed — so this is an explicit
    /// recovery hook rather than an event.
    public mutating func resetToIdle() {
        mode = .idle
    }

    /// The exclusion table.
    static func transition(
        from mode: CaptureMode,
        on event: CaptureEvent,
        in capabilities: CaptureCapabilities
    ) -> (CaptureMode, CaptureEffect) {
        switch mode {
        case .idle:
            switch event {
            case .screenshotRequested:
                return capabilities.contains(.screenshot)
                    ? (.capturing, .beginCapture)
                    : (.idle, .notYetAvailable)
            case .recordRequested:
                return capabilities.contains(.recording)
                    ? (.recording, .beginRecording)
                    : (.idle, .notYetAvailable)
            case .scrollRequested:
                return capabilities.contains(.scrollCapture)
                    ? (.scrollCapturing, .beginScrollCapture)
                    : (.idle, .notYetAvailable)
            // Not in any mode; the rest are no-ops here.
            case .overlayConfirmed, .overlayCancelled, .recordingStopped,
                 .editorOpened, .editorClosed:
                return (.idle, .none)
            }

        case .capturing:
            switch event {
            case .overlayConfirmed:
                return (.idle, .dismissAndCopy)
            case .overlayCancelled:
                return (.idle, .dismiss)
            // A second press of *any* capture action while an overlay is up
            // must not stack a second overlay.
            case .screenshotRequested, .recordRequested, .scrollRequested:
                return (.capturing, .refused)
            case .recordingStopped, .editorOpened, .editorClosed:
                return (.capturing, .none)
            }

        case .recording:
            switch event {
            case .recordingStopped:
                return (.idle, .stopRecording)
            // No screenshot while recording.
            case .screenshotRequested:
                return (.recording, .refused)
            case .recordRequested, .scrollRequested,
                 .overlayConfirmed, .overlayCancelled, .editorOpened, .editorClosed:
                return (.recording, .none)
            }

        case .scrollCapturing:
            switch event {
            // No screenshot while scroll-capturing.
            case .screenshotRequested:
                return (.scrollCapturing, .refused)
            case .scrollRequested, .recordRequested,
                 .overlayConfirmed, .overlayCancelled, .recordingStopped,
                 .editorOpened, .editorClosed:
                return (.scrollCapturing, .none)
            }

        case .editing:
            switch event {
            // No screenshot or recording while the editor is open.
            case .screenshotRequested, .recordRequested:
                return (.editing, .refused)
            case .editorClosed:
                return (.idle, .none)
            case .scrollRequested, .overlayConfirmed, .overlayCancelled, .recordingStopped,
                 .editorOpened:
                return (.editing, .none)
            }
        }
    }
}
