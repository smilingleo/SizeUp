import Annotation
import CoreGraphics
import Foundation

/// A half-open range of timeline frames, `start..<end`.
///
/// `end == nil` means "until the end of the video", which is different from
/// "until the current last frame": the video can grow when a freeze is inserted,
/// and an open-ended annotation should follow it rather than stop where the
/// video used to end.
public struct FrameRange: Equatable, Sendable {
    public var start: Int
    public var end: Int?

    public init(start: Int, end: Int?) {
        self.start = start
        self.end = end
    }

    /// Whether `frame` falls inside the range.
    public func contains(_ frame: Int) -> Bool {
        guard frame >= start else { return false }
        guard let end else { return true }
        return frame < end
    }
}

/// One of C2's nine shapes, plus the span of the video it is visible for.
///
/// This is the whole difference between the screenshot editor and the recording
/// editor: the shapes, hit-testing and drawing are reused untouched, and only
/// the lifespan is new.
public struct TimedAnnotation: Equatable, Sendable {
    public var annotation: Annotation
    public var range: FrameRange
    /// Draw the attention pulse (scale and glow, see `PulseEffect`).
    public var pulses: Bool

    public init(annotation: Annotation, range: FrameRange, pulses: Bool = false) {
        self.annotation = annotation
        self.range = range
        self.pulses = pulses
    }
}

/// A held frame: from `atBaseFrame`, repeat that frame for `holdFrames`.
///
/// Stored in *base* frames (see `RecordingEdit`), not timeline frames, so that
/// changing the playback speed does not move the freezes.
public struct FreezeKeyframe: Equatable, Sendable {
    public var atBaseFrame: Int
    public var sourceFrame: Int
    public var holdFrames: Int

    public init(atBaseFrame: Int, sourceFrame: Int, holdFrames: Int) {
        self.atBaseFrame = atBaseFrame
        self.sourceFrame = sourceFrame
        self.holdFrames = holdFrames
    }
}

/// The editable document for a finished recording.
///
/// # Three frame spaces
///
/// Freezes and playback speed make a bare frame number ambiguous, and confusing
/// the three spaces is the mistake this type exists to prevent:
///
/// - **source** — an index into the decoded file. What the decoder is asked for.
/// - **base** — source frames plus inserted freeze holds, at 1×.
/// - **timeline** — base rescaled by speed. What the UI shows, what the playhead
///   is in, and what annotation ranges are in.
///
/// Everything public is in timeline frames unless it says otherwise, because
/// that is the space the user can see.
public struct RecordingEdit: Sendable {
    /// The file being edited.
    public let videoURL: URL
    /// Frames in the decoded file.
    public let sourceTotalFrames: Int
    public let fps: Double

    /// Source frames plus freeze holds, at 1×.
    public private(set) var baseTotalFrames: Int
    /// Length in timeline frames, after speed.
    public private(set) var totalFrames: Int

    public private(set) var annotations: [TimedAnnotation] = []
    /// The annotation being edited, if any. An index into `annotations`.
    public private(set) var selected: Int?
    public private(set) var freezes: [FreezeKeyframe] = []

    public private(set) var playbackSpeed: Double = 1
    /// The playhead, in timeline frames.
    public private(set) var currentFrame: Int = 0
    public var isPlaying: Bool = false

    private var redoStack: [TimedAnnotation] = []

    public init(videoURL: URL, totalFrames: Int, fps: Double) {
        self.videoURL = videoURL
        self.sourceTotalFrames = totalFrames
        self.baseTotalFrames = totalFrames
        self.totalFrames = totalFrames
        self.fps = max(fps, 1)
    }

    /// Speed is clamped away from zero everywhere it is used, so no frame
    /// mapping can divide by it.
    private static func normalize(_ speed: Double) -> Double { max(speed, 0.1) }

    // MARK: Frame spaces

    /// timeline -> base.
    public func baseFrame(forTimeline frame: Int) -> Int {
        guard baseTotalFrames > 0 else { return 0 }
        if frame >= totalFrames.clampedToAtLeast(1) - 1 {
            return baseTotalFrames - 1
        }
        let scaled = Double(frame) * Self.normalize(playbackSpeed)
        return min(Int(scaled.rounded(.down)), baseTotalFrames - 1)
    }

    /// base -> timeline.
    public func timelineFrame(forBase frame: Int) -> Int {
        guard baseTotalFrames > 0 else { return 0 }
        let scaled = Double(frame) / Self.normalize(playbackSpeed)
        return min(Int(scaled.rounded()), totalFrames)
    }

    /// timeline -> source: which frame of the file to actually decode.
    ///
    /// A timeline frame that lands inside a hold maps to that keyframe's source
    /// frame — repeating one frame is exactly what makes a freeze look frozen.
    public func sourceFrame(forTimeline frame: Int) -> Int {
        guard sourceTotalFrames > 0 else { return 0 }
        let base = baseFrame(forTimeline: frame)
        var insertedBefore = 0
        for freeze in freezes {
            if base <= freeze.atBaseFrame { break }
            if base <= freeze.atBaseFrame + freeze.holdFrames {
                // Inside this hold: show the frame it froze.
                return min(freeze.sourceFrame, sourceTotalFrames - 1)
            }
            insertedBefore += freeze.holdFrames
        }
        return min(max(base - insertedBefore, 0), sourceTotalFrames - 1)
    }

    // MARK: Playhead

    public mutating func seek(to frame: Int) {
        currentFrame = min(max(frame, 0), max(totalFrames - 1, 0))
    }

    /// Advance one frame during playback.
    ///
    /// - Returns: false at the end, so the caller can stop or loop.
    public mutating func advance() -> Bool {
        guard currentFrame + 1 < totalFrames else { return false }
        currentFrame += 1
        return true
    }

    /// Seconds of output, which is what a viewer experiences.
    public var duration: TimeInterval { Double(totalFrames) / fps }

    // MARK: Annotations

    /// Add `annotation` starting at `frame`, and select it.
    ///
    /// The default end is the end of the freeze the frame sits in, or one second
    /// later — a shape that vanished on the next frame would be invisible, and a
    /// shape that ran to the end would need trimming every time.
    @discardableResult
    public mutating func add(_ annotation: Annotation, at frame: Int) -> Int {
        redoStack.removeAll()
        let start = totalFrames == 0 ? 0 : min(frame, totalFrames - 1)
        let timed = TimedAnnotation(
            annotation: annotation,
            range: FrameRange(start: start, end: defaultEnd(for: start)))
        annotations.append(timed)
        selected = annotations.count - 1
        return annotations.count - 1
    }

    private func defaultEnd(for frame: Int) -> Int {
        let total = max(totalFrames, 1)
        if let span = freezeSpans().first(where: { frame >= $0.start && frame < $0.end }) {
            return min(max(span.end, frame + 1), total)
        }
        let oneSecond = max(Int(fps.rounded()), 1)
        return max(min(frame + oneSecond, total), frame + 1)
    }

    /// The annotations visible at `frame`, with their indices, in draw order.
    public func annotations(at frame: Int) -> [(index: Int, annotation: Annotation)] {
        annotations.enumerated()
            .filter { $0.element.range.contains(frame) }
            .map { ($0.offset, $0.element.annotation) }
    }

    /// The topmost annotation at `point` among those visible at `frame`.
    public func hitTest(_ point: CGPoint, at frame: Int) -> Int? {
        for (index, annotation) in annotations(at: frame).reversed()
        where annotation.hitTest(point) {
            return index
        }
        return nil
    }

    public mutating func select(_ index: Int?) {
        guard let index else { selected = nil; return }
        selected = annotations.indices.contains(index) ? index : nil
    }

    /// Replace the shape of an existing annotation, keeping its lifespan.
    public mutating func update(_ index: Int, annotation: Annotation) {
        guard annotations.indices.contains(index) else { return }
        annotations[index].annotation = annotation
    }

    /// Retime an annotation. `end == nil` means "to the end of the video".
    public mutating func setRange(_ index: Int, start: Int, end: Int?) {
        guard annotations.indices.contains(index), totalFrames > 0 else { return }
        let start = min(max(start, 0), totalFrames - 1)
        // At least one frame long: a zero-length annotation can never be seen,
        // and would be impossible to select in order to fix.
        let end = end.map { min(max($0, start + 1), totalFrames) }
        annotations[index].range = FrameRange(start: start, end: end)
    }

    public mutating func togglePulse(_ index: Int) {
        guard annotations.indices.contains(index) else { return }
        annotations[index].pulses.toggle()
    }

    public mutating func remove(_ index: Int) {
        guard annotations.indices.contains(index) else { return }
        redoStack.append(annotations.remove(at: index))
        selected = nil
    }

    /// Undo the last annotation: the selected one, else the most recent.
    public mutating func undo() {
        if let index = selected, annotations.indices.contains(index) {
            redoStack.append(annotations.remove(at: index))
            selected = nil
        } else if let last = annotations.popLast() {
            redoStack.append(last)
        }
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let restored = redoStack.popLast() else { return false }
        annotations.append(restored)
        selected = annotations.count - 1
        return true
    }

    public mutating func clearAnnotations() {
        annotations.removeAll()
        redoStack.removeAll()
        selected = nil
    }

    /// Whether anything would be lost by closing without exporting.
    public var hasEdits: Bool {
        !annotations.isEmpty || !freezes.isEmpty
            || abs(playbackSpeed - 1) > .ulpOfOne
    }

    // MARK: Freezes

    /// The freeze holds as timeline spans, `start..<end`.
    public func freezeSpans() -> [(start: Int, end: Int)] {
        freezes.map { freeze in
            (timelineFrame(forBase: freeze.atBaseFrame),
             min(timelineFrame(forBase: freeze.atBaseFrame + freeze.holdFrames + 1),
                 totalFrames))
        }
    }

    /// Insert a hold of `holdFrames` timeline frames at `frame`.
    ///
    /// The timeline grows, so every annotation after the insertion point shifts
    /// by the same amount — otherwise labels would drift off the moments they
    /// were placed on.
    ///
    /// - Returns: the number of timeline frames actually inserted.
    @discardableResult
    public mutating func insertFreeze(at frame: Int, holdFrames: Int) -> Int {
        guard holdFrames > 0, totalFrames > 0, baseTotalFrames > 0 else { return 0 }
        redoStack.removeAll()

        let frame = min(frame, totalFrames - 1)
        let atBase = baseFrame(forTimeline: frame)
        let source = sourceFrame(forTimeline: frame)
        let baseHold = Self.outputDurationToBase(holdFrames, speed: playbackSpeed)

        let oldTotal = totalFrames
        baseTotalFrames += baseHold
        totalFrames = Self.outputFrameCount(baseTotalFrames, speed: playbackSpeed)
        let inserted = totalFrames - oldTotal

        freezes.append(FreezeKeyframe(atBaseFrame: atBase, sourceFrame: source,
                                      holdFrames: baseHold))
        freezes.sort { $0.atBaseFrame < $1.atBaseFrame }

        // Shift what comes after. `>` not `>=`: an annotation starting exactly at
        // the insertion point should stay put and be held along with the frame
        // it was placed on, which is usually the point of freezing there.
        for i in annotations.indices {
            if annotations[i].range.start > frame {
                annotations[i].range.start += inserted
            }
            if let end = annotations[i].range.end, end > frame {
                annotations[i].range.end = min(end + inserted, totalFrames)
            }
        }
        return inserted
    }

    /// Remove the freeze covering `frame`, if any.
    @discardableResult
    public mutating func removeFreeze(at frame: Int) -> Bool {
        let spans = freezeSpans()
        guard let hit = spans.indices.first(where: {
            frame >= spans[$0].start && frame < spans[$0].end
        }) else { return false }

        let removed = freezes.remove(at: hit)
        let oldTotal = totalFrames
        baseTotalFrames = max(baseTotalFrames - removed.holdFrames, sourceTotalFrames)
        totalFrames = Self.outputFrameCount(baseTotalFrames, speed: playbackSpeed)
        let dropped = oldTotal - totalFrames

        let span = spans[hit]
        for i in annotations.indices {
            if annotations[i].range.start >= span.end {
                annotations[i].range.start = max(annotations[i].range.start - dropped, 0)
            }
            if let end = annotations[i].range.end, end >= span.end {
                annotations[i].range.end = max(end - dropped, annotations[i].range.start + 1)
            }
        }
        clampRangesToTotal()
        seek(to: currentFrame)
        return true
    }

    // MARK: Speed

    /// Set playback speed, rescaling the timeline and every annotation range.
    ///
    /// Ranges have to move: they are stored in timeline frames, so leaving them
    /// alone at 2× would halve every annotation's on-screen duration and slide
    /// it to a different moment of the video.
    public mutating func setPlaybackSpeed(_ speed: Double) {
        let old = playbackSpeed
        let new = Self.normalize(speed)
        guard abs(new - old) > .ulpOfOne else { return }

        playbackSpeed = new
        totalFrames = Self.outputFrameCount(baseTotalFrames, speed: new)

        for i in annotations.indices {
            let start = Self.scaleTimelineFrame(annotations[i].range.start,
                                               from: old, to: new)
            annotations[i].range.start = min(start, max(totalFrames - 1, 0))
            if let end = annotations[i].range.end {
                annotations[i].range.end = min(
                    max(Self.scaleTimelineFrame(end, from: old, to: new),
                        annotations[i].range.start + 1),
                    totalFrames)
            }
        }
        currentFrame = min(Self.scaleTimelineFrame(currentFrame, from: old, to: new),
                           max(totalFrames - 1, 0))
    }

    private mutating func clampRangesToTotal() {
        for i in annotations.indices {
            annotations[i].range.start = min(annotations[i].range.start,
                                             max(totalFrames - 1, 0))
            if let end = annotations[i].range.end {
                annotations[i].range.end = min(max(end, annotations[i].range.start + 1),
                                               totalFrames)
            }
        }
    }

    static func outputFrameCount(_ baseFrames: Int, speed: Double) -> Int {
        Int(max((Double(max(baseFrames, 1)) / normalize(speed)).rounded(), 1))
    }

    static func outputDurationToBase(_ outputFrames: Int, speed: Double) -> Int {
        Int(max((Double(max(outputFrames, 1)) * normalize(speed)).rounded(), 1))
    }

    static func scaleTimelineFrame(_ frame: Int, from old: Double, to new: Double) -> Int {
        Int((Double(frame) * normalize(old) / normalize(new)).rounded())
    }
}

extension Int {
    func clampedToAtLeast(_ minimum: Int) -> Int { Swift.max(self, minimum) }
}
