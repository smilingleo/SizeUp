# C4 — the recording editor

Ported from `src/editor/` in the Rust ClipShot (~4,450 lines across
`model.rs`, `timeline.rs`, `view.rs`, `window.rs`, `minibar.rs`, `decoder.rs`,
`export.rs`, `effects.rs`).

## What it is

After a recording stops, instead of going straight to a save dialog, the video
opens in an editor that can:

1. **Play back** — play/pause, scrub, step, loop; a timeline with a playhead.
2. **Annotate over time** — the same nine shapes C2 already ships, but each one
   carries a frame range, so a label can appear at 0:03 and leave at 0:06.
3. **Pulse** — a per-annotation attention effect (scale + yellow glow, 2Hz).
4. **Freeze** — insert a hold at a frame: the timeline grows, that source frame
   repeats for the hold, and everything after it shifts.
5. **Change speed** — 0.5×–2×, which rescales the timeline *and* every
   annotation range so edits keep their meaning.
6. **Export** — burn the visible annotations into a new H.264 file.

## Why the existing work carries most of it

`Annotation` (C2) already holds the nine shapes, hit-testing, and the renderer.
The editor's annotation is just `Annotation` plus a lifespan:

```swift
struct TimedAnnotation { var annotation: Annotation; var range: FrameRange; var pulses: Bool }
```

So this milestone is about **time**, not about shapes. The renderer is reused
untouched; the compositor pattern from C2 is reused for burn-in.

## The one genuinely subtle part: three frame spaces

Freeze keyframes and playback speed mean "frame 40" is ambiguous. There are
three spaces, and mixing them is the bug this port is most likely to have:

| Space | Meaning |
|---|---|
| **source** | an index into the decoded file — what the decoder is asked for |
| **base** | source frames plus inserted freeze holds, at 1× |
| **timeline** | base rescaled by playback speed — what the UI shows and what annotation ranges are in |

The mappings, matching Rust exactly:

```
base    = floor(timeline * speed)          // clamped to base_total-1 at the end
timeline = round(base / speed)             // clamped to total
outputFrameCount(base, speed) = max(1, round(base / speed))
outputDurationToBase(out, speed) = max(1, round(out * speed))
scaleTimelineFrame(f, old, new) = round(f * old / new)
```

`source` is derived from `base` by walking the freeze keyframes and subtracting
the holds inserted before it — a frame *inside* a hold maps to that keyframe's
source frame, which is what makes the hold look frozen.

Speed is `max(0.1, speed)` everywhere, so a zero can never divide.

## Layering

A new target, because this is a coherent body of logic that is neither "a
shape" nor "a screen grab":

```
VideoEdit  ->  Annotation, Capture      (AppKit-free: CoreGraphics/CoreText/AVFoundation)
OverlayUI  ->  ... + VideoEdit          (the editor window, AppKit)
App        ->  wires stop-recording to the editor
```

`VideoEdit` may depend on both `Annotation` and `Capture` — it is the first
place that legitimately needs the renderer *and* the codec, which is exactly
why `Compositor` had to live in `App` in C2. Putting export here instead keeps
`App` thin.

## Order of work — done

1. ✅ **Model** (`RecordingEdit`) — timed annotations, freeze, speed, undo, the
   three frame spaces. 44 tests.
2. ✅ **Decoder** (`VideoDecoder` in `Capture`) — random-access reads with an LRU
   cache, plus a forward-only reader for export. Both tolerances pinned to zero
   for frame accuracy, which the Rust original does not do.
3. ✅ **Export** — decode, draw, encode; verified by decoding the result.
4. ✅ **Bridge** (`EditorBridge`) — the pure glue between C2's `Editor` and the
   timed document. Where the off-by-ones would live, so it is tested hardest.
5. ✅ **UI** — `RecordingEditorWindow`, `RecordingCanvasView`, `TimelineView`,
   `ExportProgressWindow`.
6. ✅ **Wiring** — stopping a recording opens the editor; export or discard.

## Two bugs worth recording

**`VideoEncoder.finish()` deadlocked.** It waited on a `DispatchGroup` for
`finishWriting`'s callback. That blocks the calling thread, but the callback
needs a thread of its own, so several encoders finishing at once exhausted the
cooperative pool and the process hung — which is how it was found, when the full
test suite stopped completing. It also froze the UI for the length of every
flush, since a recording stops on the main actor. Now `async`, awaiting a
continuation. Regression test: ten concurrent finishes.

**`AVAssetImageGenerator` is not frame-accurate by default.** Both time
tolerances default to unbounded, so it returns the nearest keyframe — up to a
second away on a 30fps H.264 file. The Rust original leaves them alone, which
means its scrubbing is approximate. Pinning both to `.zero` is what makes an
annotation land on the frame it was drawn on.

## A note on testing video

Colour is not a usable frame identifier: H.264 stores BT.709 YUV at limited
range, so a flat sRGB fill comes back shifted by as much as 27/255 — more than
the gap between adjacent test frames. Frames are identified *spatially* instead,
by the length of a white bar, which survives the round trip to within a pixel.

Blur looks broken over regular stripes, because a 10-unit mosaic beats against a
24-unit period. It is not broken. This is the second time that scene has caused
a false alarm.

## Deliberately out of scope

- The zoom/pan keyframe feature (`view.rs` zoom groups) — a second timeline
  concept on top of freeze, and not needed to make a recording useful.
- Audio. The recorder captures none, so there is nothing to edit.
