# ClipShot (merged) — Design

**Date:** 2026-08-21
**Status:** Approved 2026-08-21 — all six review decisions answered. C1 implementation plan:
`docs/superpowers/plans/2026-08-21-clipshot-c1.md`

## Problem

Two menu-bar apps on this Mac do adjacent jobs:

- **Sizeup2** (this repo) — a window manager. Halves, quarters, full screen, center,
  snap back, multi-display, Spaces, size cycling, gaps, skip list, rebindable shortcuts,
  SizeUp import. Swift, six SPM targets, M1–M5 complete, daily driver.
- **ClipShot** (`../screenshot`) — a screen-capture suite. Region screenshot with eleven
  annotation tools, screen recording to H.264 MP4 with a frame-by-frame editor, and scroll
  capture that stitches manually scrolled content into one tall image. Rust (~15.5k lines)
  on raw `objc2` bindings to AppKit / CoreGraphics / ScreenCaptureKit / AVFoundation.

The goal is **one app**: ClipShot's features merged into Sizeup2 and rewritten in Swift, the
result renamed ClipShot, with the settings window and menu-bar menu redesigned as a single
coherent surface instead of two apps' worth bolted together. This document is the design for
that merge. It was reviewed and approved on 2026-08-21; the C1 implementation plan is at
`docs/superpowers/plans/2026-08-21-clipshot-c1.md`.

## What is being merged (inventory)

### Sizeup2 today

| Target | Responsibility | Depends on |
|---|---|---|
| `Geometry` | Pure frame math, no AppKit | — |
| `WindowKit` | Accessibility API reads/writes, coordinate conversion | `Geometry`, `SpaceKit` (for `_AXUIElementGetWindow`) |
| `Hotkeys` | Carbon `RegisterEventHotKey` registration/dispatch | — |
| `SpaceKit` | Private SkyLight Space moves; the only private-API target | `Geometry` |
| `Core` | `ActionRouter`, keymap resolution, routing logic | `Geometry`, `WindowKit`, `Hotkeys` |
| `Config` | Codable DTOs for the hand-editable JSON settings file | `Geometry` |
| `App` | Status item, menu, SwiftUI Preferences, wiring | all |

15 window actions bound by default (`Action` has 7 case labels covering 19 values;
the 4 dead SizeUp bindings — `display.above`/`display.below` and `space.above`/`space.below`
— ship unbound, as M5 established). Settings JSON at `~/Library/Application Support/Sizeup2/settings.json`
(becomes `ClipShot/` after the rename — see §Renaming). One permission: Accessibility.

### ClipShot today (Rust module → what it does)

| Module | Lines | Responsibility |
|---|---|---|
| `app.rs` | 2417 | AppDelegate: hotkey polling, mode state machine (capture / recording / scroll / editor), toolbar + editor orchestration, save/clipboard actions |
| `overlay/` | ~1360 | Full-screen region-selection window; the annotation canvas (draw, select, move, resize handles) |
| `toolbar/` | ~970 | Floating NSPanel: 11 tool buttons + playback/zoom/action button sets; second-level style panel (9 color swatches, stroke presets, font-size slider) |
| `editor/` | ~4300 | Video/image editor: AVAssetReader decoder, timeline with annotation-span markers, per-annotation mini bar (start/end handles, hold freeze keyframes 1/2/3/5 s, pulse), playback speed 0.5–2×, reverse, zoom/pan for tall images, export with annotations + lifecycle effects composited |
| `annotation/` | ~1700 | Annotation model (arrow, rect, ellipse, pencil, text, callout, highlight, step, blur, crop), CoreGraphics renderer, inline text input |
| `recording.rs` / `encoder.rs` | ~730 | 30 fps pull-capture via `SCScreenshotManager`, cursor capture, click ripples, AVAssetWriter H.264 MP4, elapsed-time frame padding |
| `scroll_capture.rs` / `stitch.rs` / `scroll_provider.rs` | ~1900 | Timer-driven capture loop while the user scrolls; browser/terminal/native provider detection; stabilization; distinct-frame dedup; overlap detection (hash / SAD / terminal methods) and stitching into a tall image |
| `capture.rs` / `screen.rs` / `border.rs` / `actions.rs` | ~900 | ScreenCaptureKit display capture with window exclusion, display-under-cursor lookup, recording border window, clipboard/save/crop-and-composite |
| `config.rs` / `settings.rs` / `statusbar.rs` / `hotkey.rs` | ~1200 | INI config at `~/.config/clipshot/config.ini`, NSAlert settings dialog (3 text fields + login checkbox), status menu, global-hotkey registration |

Three hotkeys: ⌃⌘A screenshot, ⌃⌘Z record, ⌃⌘S scroll capture. One permission: Screen
Recording. `LSUIElement`, ad-hoc signed, bundle ID `com.smilingleo.clipshot`.

## Decisions that need review

All six were reviewed and answered on 2026-08-21; the decisions below are final and are
repeated in the sections they affect.

1. **App identity: rename to ClipShot.** The display name, executable, settings path, icon,
   and every user-facing string become ClipShot. The bundle identifier stays
   `com.lliu.sizeup2` — the Accessibility grant is bound to it and must never change — so the
   identifier becomes an implementation detail under the new name. See §Renaming.
2. **Menu layout: submenus.** The 15 window actions group into three submenus (`Window`,
   `Display`, `Spaces`) plus a top-level capture section. See §Menu.
3. **Settings window: three tabs.** **General** (login item, permission status, capture
   behavior), **Window** (today's General-tab content), **Shortcuts** (all 18 bound actions
   — 15 window + 3 capture — in one unified recorder). "Open at Login" and both importers
   move out of the menu into Settings. See §Settings.
4. **Editor scope: full port in v1.** The recording editor (~4300 lines of Rust) is ported,
   as its own milestone after raw recording works.
5. **New capture settings: both toggles.** "Show cursor in recordings" and "Show click
   ripples", both default on.
6. **Help item: kept.** The ClipShot docs site is published and stays linked from the menu;
   it documents the capture side of the merged app.

## Identity and permissions

- One bundle: `ClipShot.app`, ID `com.lliu.sizeup2`, ad-hoc signed with the fixed
  identifier, `LSUIElement = true`. Build/install flow (`make dev`) unchanged apart from the
  renamed executable. See §Renaming for why the identifier is the odd one out.
- **Two independent permissions**, each gating only its own feature set:

| Permission | Gates | Prompted when | Surfaced where |
|---|---|---|---|
| Accessibility | All window actions | First launch (existing behavior) | Menu banner item + General tab row, 1 s polling until granted (existing) |
| Screen Recording | Screenshot, recording, scroll capture | First capture attempt (`CGRequestScreenCaptureAccess`) | One-time alert with "Open System Settings" button on a failed capture; General tab row |

They do not cross-gate: with only Accessibility the app is a window manager; with only Screen
Recording it is a capture tool. Neither feature waits on the other.

- `Info.plist` gains `NSScreenCaptureUsageDescription` (text adapted from ClipShot's, which
  already states capture stays on this Mac).
- Consequence to document in the README: a standalone ClipShot install's Screen Recording
  grant is bound to its own bundle ID and does **not** carry over; the merged app prompts
  once. The existing Sizeup2 Accessibility grant **is** unaffected (same bundle ID) — the
  rename is deliberate so the user keeps it.
- **One-time settings migration.** The settings file moves with the name, from
  `~/Library/Application Support/Sizeup2/settings.json` to `.../ClipShot/settings.json`.
  On first launch under the new name, if the old file exists and the new one does not, the
  app moves it (never overwrites; if the new file already exists, the old one is left in
  place and logged). The user keeps every preference across the rename.

## Renaming to ClipShot

The merged app is renamed **ClipShot** — the capture suite defines the product identity and
window management becomes a feature of it. Everything user-visible changes; one thing does
not:

| Thing | Today | After C1 |
|---|---|---|
| Display name, menus, window titles, alerts, banners | Sizeup2 | **ClipShot** |
| Executable, `.app`, SPM package name | Sizeup2 | **ClipShot** |
| Settings file | `~/Library/Application Support/Sizeup2/settings.json` | `~/Library/Application Support/ClipShot/settings.json` (+ one-time migration) |
| Default save prefix | — (nothing is saved yet) | `clipshot-` |
| Menu-bar icon | SF Symbol `rectangle.split.2x1` | ClipShot's template asset, SF Symbol fallback |
| App icon (Finder) | none | ClipShot's `AppIcon.icns` |
| **Bundle identifier** | `com.lliu.sizeup2` | **`com.lliu.sizeup2` — unchanged** |
| **Signing** | ad-hoc, fixed identifier | **unchanged** |
| **Existing Accessibility grant** | bound to the identifier | **survives** |

- The identifier stays `com.lliu.sizeup2` for the same load-bearing reason as always: the
  Accessibility grant is bound to the identifier, and a "clean" rename to
  `com.smilingleo.clipshot` would silently invalidate it. The identifier is an implementation
  detail users never see; the display name is the identity, and it becomes ClipShot. The
  Settings directory is the one place the identifier history leaks — and it moves to
  `ClipShot/` anyway, with the one-time migration above so no preference is lost.
- `Info.plist`: `CFBundleName` / `CFBundleDisplayName` → ClipShot, `CFBundleExecutable` →
  ClipShot, `CFBundleIconFile` → AppIcon, `NSScreenCaptureUsageDescription` (text from the
  Rust app's plist), `LSApplicationCategoryType` → productivity, version → 1.0.0.
  `CFBundleIdentifier` is untouched.
- `Package.swift` name, `Scripts/build-app.sh` (`APP_NAME` and the identifier comment), and
  `Makefile` pkill/install paths all follow the executable name.
- Every user-facing string — status-item accessibility descriptions, alerts, tooltips, the
  permission-waiting banners, the Spaces private-API tooltip, the quit item, NSLog prefixes —
  says ClipShot. `SizeUp` (the other product whose configuration the app imports) is never
  renamed.

## Architecture

The merge extends the existing package with five new targets, following the same philosophy:
pure logic in AppKit-free, testable targets; UI in AppKit targets; `App` joins everything.

| Target | Responsibility | Depends on | AppKit? |
|---|---|---|---|
| `Capture` | ScreenCaptureKit display capture (incl. window exclusion), display-under-cursor / frame lookup, permission preflight + request, pixel-dimension helpers (H.264 even sizes) | — | No (CoreGraphics + ScreenCaptureKit) |
| `Annotation` | Annotation model (value types) + CoreGraphics/CoreText renderer + text metrics; the 11 tools' geometry (hit-testing, resize handles, step numbering) | — | No (CoreGraphics + CoreText + Foundation only — text draws via CoreText, verified; AppKit still forbidden) |
| `Stitching` | Scroll stitching: overlap detection (hash / SAD / terminal methods), frame compositing into a tall image | — | No (CoreGraphics + Foundation for buffers) |
| `Recording` | Capture session state machine (30 fps pull-capture), AVAssetWriter H.264 encoder, cursor capture, click ripples, elapsed-time padding; also the AVAssetReader-based decoder used by the editor | `Capture` | No (AVFoundation + ScreenCaptureKit) |
| `OverlayUI` | Region-selection overlay window/view; annotation canvas interaction (draw/select/move/resize); inline text input | `Capture`, `Annotation` | Yes |
| `ToolbarUI` | Floating toolbar panel + style panel (colors, stroke presets, font size); button sets for capture vs editor contexts | `Annotation` | Yes |
| `EditorUI` | Editor window: view/model, timeline markers, mini bar, effects, export orchestration, zoom/pan for tall images | `Annotation`, `Recording` | Yes |
| `App` | Status item + menu, settings window, capture-session orchestration (mode exclusions), permission banners, importers' UI wiring | all | Yes |

Existing targets are unchanged except:

- `Geometry`: the `Action` enum gains three cases — `.captureScreenshot`,
  `.startRecording`, `.toggleScrollCapture`. They are routing identifiers only; no capture
  math enters `Geometry`.
- `Core`: `DefaultKeymap` and `KeymapResolver` pick up the three new actions automatically
  (they operate over `Action`). `ActionRouter` gains nothing — App dispatches capture actions
  to the capture session, exactly as it already dispatches Space actions to `SpaceKit` via a
  protocol. This is what makes shortcut **conflict detection unified across all 18 bound
  actions**:
  a user cannot bind ⌃⌘A to "Left Half" and silently kill screenshot capture, because the
  resolver sees both.
- `Config`: `ShortcutSetting`'s known-identifier set gains the three capture identifiers;
  `Settings` gains one nested DTO:

```json
{
  "gaps": { "inner": 0, "outer": 0 },
  "cycle": [ { "occupied": 1, "columns": 2 } ],
  "skippedBundleIdentifiers": [],
  "followsWindowToSpace": true,
  "shortcutOverrides": [ /* window + capture actions */ ],
  "capture": { "showCursorInRecordings": true, "showClickRipples": true }
}
```

  Same file, same rules: `decodeIfPresent` defaults, pretty-printed sorted-key output, atomic
  write, corrupt-file quarantine. After the rename the file lives at
  `~/Library/Application Support/ClipShot/settings.json` (migrated from `Sizeup2/` on first
  launch — see §Renaming). One settings file replaces ClipShot's INI.

### Layering lint updates

`Scripts/lint-layering.py` gains rows for the new targets, keeping the existing style
(forbidden imports per target):

- `Capture` — forbids: AppKit, Carbon, Config, Core, Hotkeys, SpaceKit, WindowKit, Annotation, Stitching, Recording
- `Annotation` — forbids: AppKit, Carbon, and every other target. It imports CoreGraphics + CoreText + Foundation (Foundation for the `CFAttributedString` text bridging — verified, probe 7: text renders in a bitmap context with no AppKit; the Rust app drew text via `NSFont`, but Swift's CoreText needs nothing more).
- `Stitching` — same shape as `Annotation` (Foundation for byte buffers)
- `Recording` — forbids: AppKit, Carbon, Config, Core, Hotkeys, SpaceKit, WindowKit, Annotation, Stitching
- UI targets (`OverlayUI`, `ToolbarUI`, `EditorUI`) and `App` — unconstrained, as `App` is today

The private-API quarantine is unchanged: ScreenCaptureKit and AVFoundation are public API, so
`SpaceKit` remains the only target that can touch private symbols.

### Capture-session orchestration

ClipShot's `app.rs` interleaves five modes (idle, capturing, recording, scroll-capturing,
editing) with hard exclusions (no screenshot while recording/editing/scroll-capturing; no
recording while editing). In the merged app this lives in `App` as a small explicit state
machine (`CaptureSession`) rather than scattered booleans — same transitions, but:

- Transitions are one function of `(state, event)`, so the exclusion table is reviewable and
  testable with fake collaborators.
- The **menu rebuild** and **status icon** are derived from the state (see §Menu), not mutated
  ad hoc at each transition site — ClipShot's `enter_recording_mode` / `exit_recording_mode`
  pair of methods is exactly the drift-prone pattern this avoids.
- Hotkey dispatch routes through it: a capture hotkey in the wrong state is ignored with an
  `NSLog`, matching ClipShot's behavior.

## Menu redesign

One status item, three icon states:

| State | Icon | When |
|---|---|---|
| Normal | ClipShot's template icon (the Rust app's `statusbar_icon.png`, copied into `Resources/`; SF Symbol `rectangle.split.2x1` as decode fallback) | Idle |
| Active capture | `record.circle.fill` | Recording or scroll-capturing |
| Problem | `exclamationmark.triangle` (unchanged) | Any hotkey registration failure |

### Normal menu

```
[Accessibility / hotkey banners, when applicable]   ← existing behavior, unchanged;
                                           always above everything else
─────────────
Screenshot                          ⌃⌘A
Record Screen                       ⌃⌘Z
Scroll Capture                      ⌃⌘S
─────────────
Window ▸
    Left Half                       ⌃⌥⌘←
    Right Half                      ⌃⌥⌘→
    Top Half                        ⌃⌥⌘↑
    Bottom Half                     ⌃⌥⌘↓
    ─────────────
    Upper Left                      ⌃⌥⇧←
    Upper Right                     ⌃⌥⇧↑
    Lower Left                      ⌃⌥⇧↓
    Lower Right                     ⌃⌥⇧→
    ─────────────
    Full Screen                     ⌃⌥⌘M
    Center                          ⌃⌥⌘C
    Snap Back                       ⌃⌥⌘/
Display ▸
    Next Display                    ⌃⌥←
    Previous Display                ⌃⌥→
Spaces ▸
    Next Space                      ⌃⌘→
    Previous Space                  ⌃⌘←
─────────────
Settings…                           ⌘,
Help                                (ClipShot documentation)
─────────────
Quit ClipShot                       ⌘Q
```

Design notes:

- **Capture items stay top-level** — they are the highest-frequency new actions and should
  not be one extra click deep. Window actions go into submenus because 15 flat rows is what
  makes today's menu scroll; grouping by the three natural families (arrange / move between
  displays / move between Spaces) keeps every action reachable in two clicks while halving
  the top-level height.
- **Everything today's menu does is preserved**: per-item shortcut display, "(no shortcut)"
  suffix for deliberately unbound actions, "(…explanation…)" suffix when another app claimed
  a shortcut, "(unavailable on this macOS)" beside Space items when SkyLight symbols are
  missing, the Accessibility waiting banner, and the hotkey-handler-failure banner. These
  behaviors move into the submenus unchanged — they are the hard-won honesty of M1–M5.
- **Removed from the menu**: "Import Shortcuts from SizeUp…" (→ Settings → Shortcuts, where
  the new "Import Shortcuts from ClipShot…" lives alongside it) and "Open at Login" (→
  Settings → General). The menu's job is invoking actions; configuration lives in one place.
  The Help item stays, since it navigates to the docs rather than configuring.

### Recording / scroll-capturing menu

The menu collapses to the active operation, mirroring ClipShot:

```
Stop Recording                      ⌃⌘Z      (or "Stop Scroll Capture   ⌃⌘S")
─────────────
Settings…                           ⌘,
Quit ClipShot                       ⌘Q
```

Window actions are hidden rather than disabled while a capture is in flight: the overlay and
editor are modal to the user's attention, and a menu full of greyed rows invites clicks that
do nothing. (Hotkeys for window actions remain registered — pressing one while recording is
harmless and matches ClipShot, where they simply coexist.)

## Settings redesign

Same shell as today (AppKit `NSWindow` + SwiftUI content, single reused window, reload-on-show
so hand-edits are never clobbered). The two tabs become three:

### Tab 1 — General

```
Launch at login        [toggle]      ← SMAppService, same honest degradation as today
                                        (greyed + tooltip when ad-hoc signing blocks it)

Permissions
  Accessibility        ● Granted     /  ○ Not granted   [Open System Settings]
  Screen Recording     ● Granted     /  ○ Not granted   [Open System Settings]

Capture
  Show cursor in recordings        [toggle, default on]
  Show click ripples               [toggle, default on]
```

- The permission rows are live (re-read on show, same as the login toggle re-reads
  `SMAppService` state), with deep links to `Privacy_Accessibility` and
  `Privacy_ScreenCapture`. This is the one place both permissions are visible together; the
  menu still carries its banners for the in-the-moment case.
- The two capture toggles map to `capture.showCursorInRecordings` /
  `capture.showClickRipples` and take effect from the next recording.

### Tab 2 — Window

Today's General tab, unchanged in content: Gaps (two steppers), Spaces (follow toggle +
explanatory text), Size cycling (catalogue toggles + custom-span/dropped-entry notes), Skip
list (picker + per-row remove). It is renamed from "General" to "Window" because "General"
now means the app-level tab.

### Tab 3 — Shortcuts

One unified recorder for **all 18 bound actions** (15 window + 3 capture), in two sections:

```
Capture
  Screenshot          ⌃⌘A        [Record] [Clear]
  Record Screen       ⌃⌘Z        [Record] [Clear]
  Scroll Capture      ⌃⌘S        [Record] [Clear]
Window
  Left Half           ⌃⌥⌘←       [Record] [Clear]
  … the remaining 14 window rows, same order …

[Restore Defaults]
[Import Shortcuts from SizeUp…]     (disabled + tooltip when the plist is absent)
[Import Shortcuts from ClipShot…]   (disabled + tooltip when config.ini is absent)
```

- The existing recorder machinery (`ShortcutsViewModel`, suspend/resume of global hotkeys
  while recording, displacement messages, conflict messages for hand-edited files) is reused
  unchanged; it already operates over `Action`, so the three capture rows come for free.
- **Import Shortcuts from ClipShot…**: a `ClipShotImporter` in `Config`, symmetric to
  `SizeUpImporter`. Reads `~/.config/clipshot/config.ini` (the existing parser's format:
  `capture_hotkey=`, `record_hotkey=`, `scroll_capture_hotkey=`), converts the three strings
  into `ShortcutSetting`s, and offers the same confirm-then-report flow as the SizeUp import.
  It is the migration path for anyone who rebound ClipShot's hotkeys; after a successful
  import the INI is left untouched (the user can delete ClipShot at their leisure).
- Both importers replace **all** overrides, and both say so in the confirm dialog — same
  destructive-action treatment the SizeUp import already has.

## Feature porting (parity list)

Ported with behavioral parity to ClipShot 1.0.8:

**Screenshot.** Display-under-cursor capture via ScreenCaptureKit (never the deprecated
`CGWindowListCreateImage` path); borderless keyable overlay at `kCGOverlayWindowLevel`; drag
region selection; all eleven tools — select (move/resize with handles), arrow, rectangle,
ellipse, pencil, text (inline input), callout (adjustable pointer), highlight, numbered step,
blur (pixelate), crop; style panel (9 colors, thin/medium/thick strokes, font-size slider);
tool hotkeys S/A/R/E/P/T/Q/H/N/B/C and width keys 1/2/3; undo/redo; confirm → clipboard,
save → PNG via `NSSavePanel` with ClipShot's existing timestamped filename convention
(`clipshot-capture-…` — unchanged by the rename, since the app is now ClipShot), crop-and-composite rendering; Esc cancels everything
without saving or copying.

**Screen recording.** Region selection reuses the overlay in recording mode; 30 fps capture of
the selected region into a temp MP4 (H.264, even dimensions); click-through red border window
excluded from capture via `SCContentFilter`; cursor capture and left/right click ripples
(composited per frame); elapsed-time frame padding on stop; stop via ⌃⌘Z or the menu; then
the editor opens.

**Editor.** Window sized to 80% of the screen cap (existing behavior); AVAssetReader decoder;
timeline slider with duration label and annotation-span/hold markers; playback speed 0.5–2×;
forward/reverse playback; all annotation tools over video frames; per-annotation mini bar
(start/end handles, hold freeze keyframes at 1/2/3/5 s, pulse effect); Space play/pause, Esc
cancel (discard), ⌘Z/⌘⇧Z undo/redo, Delete removes the selected annotation; export bakes
annotations + lifecycle effects + speed change into a new MP4; closing via the window button
offers save of the raw recording; cancel discards without saving. Single-frame mode serves the
scroll-capture image with zoom (0.05–4×) and pan.

**Scroll capture.** Region selection auto-starts the capture loop; provider detection
(browser / terminal / native / generic) drives stabilization attempts, settle delays, and the
overlap method; distinct-frame dedup; per-pair overlap hints bound the stitch search;
stitching (hash / SAD / terminal methods) produces one tall PNG; app log output is suppressed
while a terminal scroll capture runs so the target's content does not change mid-stitch; stop
via ⌃⌘S or the menu, then the editor opens in single-frame mode.

**Multi-monitor.** Capture targets the display containing the cursor at trigger time and locks
to it (existing ClipShot behavior); negative-coordinate display layouts are handled with the
same top-left/bottom-left discipline `WindowKit` already enforces — one conversion point,
tested.

Not ported in v1:

- **Headless CLI** (`clipshot scroll-capture` subcommand). A menu-bar app has no CLI surface;
  if it is ever needed again it becomes a separate SPM executable target reusing the same
  capture targets.
- **App Store / StoreKit / trial machinery.** Already removed from ClipShot (free since
  1.0.8); nothing to port.
The one surface piece that *is* ported: the **Help item** — the docs site is published and
decision 6 kept it, so it links to the same site, which documents the merged app's capture
features.

## Testing

New test targets, all Swift Testing under the existing harness:

- `AnnotationTests` — model invariants (handle kinds per tool, step numbering, blur/crop
  rect validation), hit-testing against synthetic layouts, renderer smoke tests drawing into
  a bitmap context and asserting pixel results.
- `StitchingTests` — synthetic frame pairs with known overlap (exact, partial, none), terminal
  method on monospace-style frames, hint-bounded search, degenerate inputs (empty, identical,
  sub-minimum size). This is the port's highest-risk pure logic and gets the most coverage.
- `CaptureTests` — display lookup against injected display data (including negative origins),
  even-dimension rounding for H.264, region normalization.
- `RecordingTests` — encoder settings validation, frame-padding math, ripple fire/prune
  windows, click-counter edge cases.
- Existing targets keep their tests; `KeymapResolverTests` and `DefaultKeymapTests` gain the
  three capture actions (including a conflict test: binding ⌃⌘A to a window action displaces
  Screenshot, exactly like today's displacement semantics).
- `ClipShotImporterTests` — fixture INI (a copy of a real `config.ini` committed under
  `Tests/Fixtures/`, mirroring the SizeUp plist fixture), including a rebound-hotkeys case.

Manual verification docs per milestone continue the existing convention
(`docs/superpowers/C?-manual-verification.md`), each checked against the installed ClipShot
side by side — that is the behavioral oracle for the port until the new app supersedes it.

## Build and packaging

- `Scripts/build-app.sh`: executable and bundle name become ClipShot (the signed identifier
  stays `com.lliu.sizeup2`); `Info.plist` gains `CFBundleIconFile` and
  `NSScreenCaptureUsageDescription`, version moves to 1.0.0. Bundle ID, ad-hoc signing, and
  the fixed-identifier rule are otherwise untouched.
- `Makefile`: pkill/install paths follow the renamed executable; `make test` and lints
  unchanged.
- Assets: `statusbar_icon.png` (menu bar, template) and `AppIcon.icns` are copied into
  `Resources/` from the Rust repo.

## Milestones

Following the completed M1–M5, the capture work lands as C1–C6. Each milestone ends with a
manual-verification pass against ClipShot and all lints green.

- **C1 — Rename + capture foundation.** Rename to ClipShot: display name, executable,
  `Info.plist` (icon, usage description, version), build scripts, every user-facing string,
  settings path + one-time migration of the existing `Sizeup2/` file; bundle ID and signing
  unchanged. New targets `Capture`, `Annotation` (model only), `OverlayUI` (region selection
  only). Screen Recording permission flow; screenshot → confirm to clipboard / save to file.
  Redesigned menu (capture section, submenus, Help, recording-state collapse stub) and
  three-tab settings shell with the General tab complete (login, permissions, capture toggles
  wired to no-op until C3). Unified keymap: three capture actions with ClipShot's defaults,
  Shortcuts tab listing all 18 rows, `ClipShotImporter`. *The merged app is now a daily
  driver for both jobs, minus annotation and recording.*
- **C2 — Annotation.** Full renderer, canvas interaction (select/move/resize), style panel,
  text input, crop, undo/redo. Screenshot parity with ClipShot.
- **C3 — Recording.** `Recording` target: capture session state machine, encoder, border
  window, cursor + ripples, stop flow, raw MP4 save (editor not yet — save dialog instead).
  Menu/icon recording states live. Capture toggles take effect.
- **C4 — Editor.** Decoder, editor window/view/model, timeline, mini bar, effects, export.
  Recording parity with ClipShot.
- **C5 — Scroll capture.** Provider detection, capture loop, `Stitching`, tall-image editor
  mode (zoom/pan), log suppression. Full feature parity.
- **C6 — Polish and handoff.** README rewrite (one app, two permission stories, migration
  notes for SizeUp and ClipShot users), final side-by-side verification pass, uninstall
  guidance for the old apps.

## Risks

| Risk | Mitigation |
|---|---|
| The editor is the largest port (~4300 lines of Rust across eight files) and the most UI-stateful | Its own milestone (C4), after raw recording proves the capture pipeline; decoder/export live in `Recording` where they are testable without windows |
| Behavioral drift between Rust original and Swift port | ClipShot installed side by side as the oracle during C1–C5; manual-verification checklists per milestone; pure logic (stitching, annotation geometry) pinned by unit tests with synthetic fixtures |
| Screen Recording grant does not carry over from ClipShot's bundle ID | Documented in README and surfaced on first capture attempt; one-time re-grant is the cost of the merge |
| 30 fps pull-capture timing (ClipShot's proven approach) vs SCStream push delivery | Keep pull-capture via `SCScreenshotManager` for parity; SCStream push is a later optimization, not a v1 requirement |
| Two permissions interacting with hotkey registration (e.g. capture hotkeys registered but Screen Recording missing) | Hotkeys register regardless of permission (as today for Accessibility); each action checks its own permission at dispatch and surfaces it — no cross-gating |
| `SpaceKit` private API remains a macOS-update hazard | Unchanged by this merge; still quarantined to one target, still degrades visibly |
| The swift-testing/Xcode CI hazard | Unchanged by this merge; new test targets follow the same pattern and inherit the same note |
