import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Records a region of one display to an H.264 MP4.
///
/// The loop is deliberately dumb: every tick, capture the region, draw any live
/// click ripples over it, and append it as many times as the wall clock says it
/// should appear. All the judgement lives in `Recording` (pacing) and
/// `ClickDetector`/`ClickRippleTrack` (clicks), which are pure and tested; this
/// type only supplies real frames and real time.
///
/// The cursor is drawn by ScreenCaptureKit (`showsCursor`) rather than by hand:
/// it then looks like the user's actual cursor, including whatever shape the app
/// under it had set.
@available(macOS 14.0, *)
@MainActor
public final class ScreenRecorder {
    /// What to record, and how it should look.
    public struct Options: Sendable {
        /// The region in the display's own points, top-left origin.
        public var region: CGRect
        /// Points to pixels for that display.
        public var scale: CGFloat
        public var displayID: CGDirectDisplayID
        public var showsCursor: Bool
        public var showsClickRipples: Bool
        public init(region: CGRect, scale: CGFloat, displayID: CGDirectDisplayID,
                    showsCursor: Bool = true, showsClickRipples: Bool = true) {
            self.region = region
            self.scale = scale
            self.displayID = displayID
            self.showsCursor = showsCursor
            self.showsClickRipples = showsClickRipples
        }

        /// The output size in pixels, both even for H.264.
        public var pixelSize: (width: Int, height: Int) {
            (Screenshot.even(Int((region.width * scale).rounded())),
             Screenshot.even(Int((region.height * scale).rounded())))
        }
    }

    public private(set) var isRecording = false
    public private(set) var options: Options
    public var framesWritten: Int { encoder?.framesWritten ?? 0 }

    private let encoder: VideoEncoder?
    private var startedAt: Date?
    private var lastFrame: CGImage?
    private var track = ClickRippleTrack()
    private var detector = ClickDetector()
    private let inventory: DisplayInventory
    private var display: SCDisplay?
    private var excluded: [CGWindowID] = []
    /// True while a capture is in flight. A tick that arrives before the last
    /// one finished is dropped rather than queued: queueing would let a slow
    /// display build an unbounded backlog of stale frames.
    private var isTicking = false

    public init(options: Options, url: URL, inventory: DisplayInventory) throws {
        self.options = options
        self.inventory = inventory
        let size = options.pixelSize
        encoder = try VideoEncoder(url: url, width: size.width, height: size.height)
    }

    public var url: URL? { encoder?.url }

    // MARK: Lifecycle

    /// - Parameter excluding: windows to leave out of the frame — the region
    ///   border, so the recording does not contain its own chrome. Resolved by
    ///   the caller: reading the window list is async, and this method is
    ///   called from a synchronous start path.
    public func start(display: SCDisplay, excluding windows: [CGWindowID] = []) throws {
        guard let encoder, !isRecording else { return }
        self.display = display
        self.excluded = windows
        try encoder.start()
        startedAt = Date()
        isRecording = true
    }

    /// Capture and append however many frames the elapsed time calls for.
    /// Called from a timer at `Recording.fps`.
    public func tick() async {
        guard isRecording, let encoder, let startedAt, !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        if options.showsClickRipples {
            sampleClicks()
        }

        if let frame = await captureRegion() {
            lastFrame = frame
        }
        // A dropped capture repeats the previous frame rather than leaving a
        // gap: a missing frame would shorten the video and speed it up.
        guard let frame = lastFrame else { return }

        let target = Recording.frameCount(forElapsed: Date().timeIntervalSince(startedAt))
        while encoder.framesWritten < target {
            let index = encoder.framesWritten
            guard encoder.append(composite(frame, at: index)) else {
                // A failed writer never recovers, so stop rather than spin.
                isRecording = false
                return
            }
        }
        track.prune(before: encoder.framesWritten)
    }

    /// Stop and close the file.
    /// - Returns: the finished video, or `nil` if nothing was written.
    @discardableResult
    public func finish() throws -> URL? {
        guard let encoder else { return nil }
        // Pad out to the moment the user pressed stop, so the tail of the
        // recording is not trimmed by up to a frame interval.
        if isRecording, let startedAt, let frame = lastFrame {
            let target = Recording.frameCount(forElapsed: Date().timeIntervalSince(startedAt))
            while encoder.framesWritten < target {
                guard encoder.append(composite(frame, at: encoder.framesWritten)) else { break }
            }
        }
        isRecording = false
        guard encoder.framesWritten > 0 else {
            encoder.cancel()
            return nil
        }
        try encoder.finish()
        return encoder.url
    }

    public func cancel() {
        isRecording = false
        encoder?.cancel()
    }

    // MARK: Frames

    private func captureRegion() async -> CGImage? {
        guard let display else { return nil }
        let size = options.pixelSize
        return await Screenshot.capture(
            inventory,
            display: display,
            excludingWindows: excluded,
            pixelSize: CGSize(width: size.width, height: size.height),
            showsCursor: options.showsCursor,
            sourceRect: options.region)
    }

    /// Draw the ripples over a captured frame. Returns the frame untouched when
    /// there is nothing to draw, so an idle recording costs no compositing.
    private func composite(_ frame: CGImage, at index: Int) -> CGImage {
        guard options.showsClickRipples, !track.isEmpty else { return frame }
        let width = frame.width, height = frame.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return frame }

        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Ripple positions are in region points; flip to a y-down space and
        // scale so they land where the click did at any backing scale.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: options.scale, y: options.scale)
        ClickRippleRenderer.draw(track, at: index, in: context)
        return context.makeImage() ?? frame
    }

    private func sampleClicks() {
        let left = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let right = CGEventSource.buttonState(.combinedSessionState, button: .right)
        guard detector.sample(leftDown: left, rightDown: right) else { return }
        guard let position = cursorInRegion() else { return }
        track.add(ClickRipple(position: position, frame: encoder?.framesWritten ?? 0))
    }

    /// The cursor in the region's own points, or `nil` when it is outside.
    /// CoreGraphics rather than `NSEvent.mouseLocation`, because `Capture` is
    /// AppKit-free and CG's global coordinates are already y-down like the
    /// region.
    private func cursorInRegion() -> CGPoint? {
        guard let event = CGEvent(source: nil) else { return nil }
        let global = event.location
        let bounds = CGDisplayBounds(options.displayID)
        let local = CGPoint(x: global.x - bounds.origin.x - options.region.minX,
                            y: global.y - bounds.origin.y - options.region.minY)
        guard local.x >= 0, local.y >= 0,
              local.x <= options.region.width, local.y <= options.region.height else {
            return nil
        }
        return local
    }
}
