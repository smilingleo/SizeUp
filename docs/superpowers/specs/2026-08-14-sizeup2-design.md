# Sizeup2 — Design

**Date:** 2026-08-14
**Status:** Approved, ready for implementation planning

## Problem

SizeUp (Irradiated Software) is the user's daily window manager on macOS 26 and is no
longer maintained. Usage recorded in its own preferences: 13,318 windows moved. The goal
is a replacement that reproduces the workflow exactly, then adds three things SizeUp
never had: size cycling, configurable gaps, and a per-app skip list.

## Existing configuration to reproduce

Read from `~/Library/Preferences/com.irradiatedsoftware.SizeUp.plist`:

| Feature | Shortcut | Modifier mask |
|---|---|---|
| Halves: left / right / up / down | ⌃⌥⌘ + arrows | 1835008 |
| Quarters: four corners | ⌃⌥⇧ + arrows (see below) | 917504 |
| Full screen | ⌃⌥⌘ + M (keycode 46) | 1835008 |
| Center | ⌃⌥⌘ + C (keycode 8) | 1835008 |
| Snap Back (restore previous frame) | ⌃⌥⌘ + / (keycode 44) | 1835008 |
| Next / previous monitor | ⌃⌥ + ← / → | 786432 |
| Move to space: next / prev / above / below | ⌃⌘ + arrows | 1310720 |

17 shortcuts in total. Modifier masks are `NSEvent` modifier flags; `ComboCode` values
are virtual keycodes. Both map directly to the replacement's shortcut format, which
makes automated import possible.

The quarter shortcuts use SizeUp's default arrow assignment, which is clockwise rather
than spatial:

| Shortcut | Quarter | Keycode |
|---|---|---|
| ⌃⌥⇧ ← | Upper Left | 123 |
| ⌃⌥⇧ ↑ | Upper Right | 126 |
| ⌃⌥⇧ ↓ | Lower Left | 125 |
| ⌃⌥⇧ → | Lower Right | 124 |

This looks like a misconfiguration but is not, and it is established muscle memory after
13,318 uses. Import must preserve it verbatim; the import test asserts this explicitly.

## Scope

**In scope**

- All seven feature groups above.
- Size cycling on repeated presses of a halves shortcut.
- Configurable inner gap and outer margin, defaulting to zero.
- Per-app skip list.
- One-click import of the existing SizeUp configuration.

**Out of scope**

- Drag-to-screen-edge snapping. That was Cinch, a separate product, and requires a
  full input-tracking subsystem.
- Saved window layouts and presets. Useful, but a distinct feature with its own
  persistence model. Candidate for a later version.
- Per-app default placement on launch. Requires watching window-creation events and
  fights applications that restore their own window state.

## Distribution

Personal tool, structured so it can be open-sourced later: Swift Package, no Xcode
project checked in, `swift test` runnable in CI, MIT license.

Accessibility permission is granted to a code-signing identity, not a filesystem path.
An unsigned binary loses its grant on every rebuild. Development therefore uses **ad-hoc
signing with a fixed bundle identifier** (`com.lliu.sizeup2`), which preserves the grant
across rebuilds and requires no Apple Developer account. On macOS 26 the Accessibility
entry may need to be removed and re-added once, after the first signed build.

Developer ID signing, notarization, and an update mechanism are deferred; nothing in the
design precludes adding them.

## Architecture

Six SwiftPM targets. The split exists so that the error-prone logic — frame arithmetic
and coordinate conversion — is testable without windows on screen.

| Target | Responsibility | Depends on |
|---|---|---|
| `Geometry` | Pure frame math. No AppKit. | — |
| `WindowKit` | Accessibility API reads and writes | `Geometry` |
| `Hotkeys` | Global shortcut registration | — |
| `Spaces` | Moving windows between Spaces | `WindowKit` |
| `Settings` | Preferences storage, SizeUp import | `Geometry`, `Hotkeys` |
| `App` | Status item, menu, Preferences, wiring | all |

Target: macOS 14+. SwiftUI for the Preferences window, AppKit for the status item.

### Data flow

Hotkey fires → resolve `Action` → find the frontmost application's focused window →
select the display holding the largest intersection of that window's frame → compute the
target frame (pure function) → apply it → read back the result → record it in the state
store.

## Geometry engine

```swift
func targetFrame(
    for action: Action,
    on screen: ScreenInfo,
    gaps: Gaps,
    current: CGRect?,
    cycleStep: Int
) -> CGRect
```

`Action` cases: `.half(Edge)`, `.quarter(Corner)`, `.center`, `.fullScreen`,
`.snapBack`, `.display(Direction)`, `.space(Direction)`.

Only `.half`, `.quarter`, `.center`, and `.fullScreen` are resolved by `targetFrame`.
The other three are not single-screen frame math and are dispatched before it is called:
`.snapBack` restores `preActionFrame` from the state store, `.display` recomputes the
window's existing proportional placement against a different screen, and `.space` is
handled entirely by the `Spaces` target.

Three invariants, each covered by tests:

1. **All math uses `visibleFrame`, not `frame`.** `visibleFrame` already excludes the
   menu bar and Dock, so placement stays correct for any Dock position or auto-hide
   state. Using `frame` is the most common cause of windows tucked under the Dock.
2. **Gap arithmetic divides the remaining space, not the whole space.** With inner gap
   `g` and outer margin `m`, a left third is `(visibleWidth - 2m - 2g) / 3`. Both
   values default to `0`, making default behavior byte-identical to SizeUp.
3. **Rounding leaves no seam or overlap.** On odd-pixel displays, the leading half uses
   `floor` and the trailing half takes the remainder.

Screen data is supplied through a `ScreenProvider` protocol so tests can describe
synthetic multi-display layouts.

## Cycling and window state

`WindowStateStore`, keyed by AX window ID plus PID, records per window:

- `lastAction` and the exact frame that was applied
- `preActionFrame`, captured before the first action, used by Snap Back

A press counts as a repeat only if `lastAction` equals the incoming action **and** the
window's current frame still equals the frame previously applied. Otherwise `cycleStep`
resets to zero. Consequence: moving or resizing a window by hand breaks the chain, and
the next press produces a clean half.

This is state-based rather than timer-based. A timer would cycle unexpectedly when the
user pauses to think, and produce different results for identical input.

Default cycle fractions: `[0.5, 0.667, 0.333]`, editable in the preferences plist, with
no editor UI in the first version. Each fraction is the window's share of the usable
width, anchored to the edge named by the action: ⌃⌥⌘→ therefore yields right half, then
right two-thirds, then right third. For `.half(.up)` and `.half(.down)` the fraction
applies to height instead. Cycling applies to **halves only**; a cycling quarter varies
on two axes and its landing position stops being predictable. The store is an LRU capped
at 50 windows.

## Applying frames

Accessibility uses a top-left origin on the primary display; `NSScreen` uses a
bottom-left origin. Conversion is confined to a single function in `WindowKit`, tested
against layouts that include displays positioned above and to the left of primary, since
negative coordinates are where sign errors appear.

Setting position and size is not atomic, and applications with minimum sizes clamp the
result. The write sequence is therefore position → size → position, followed by reading
back the achieved frame. **The achieved frame, not the requested frame, is recorded in
the state store**; otherwise cycle detection breaks for every window with a minimum
width.

## Hotkeys

Carbon `RegisterEventHotKey`, not a `CGEventTap`. It works while the app is in the
background and requires no Input Monitoring permission, which a tap would need for no
additional benefit at this scope.

The configured combinations do not collide with macOS 26's built-in tiling shortcuts,
which use ⌃⌥ together with `fn`. Each registration result is checked, and failures are
surfaced in Preferences rather than failing silently.

## SizeUp configuration import

On first launch, if `com.irradiatedsoftware.SizeUp.plist` is present, offer import.
`ComboCode` and `ComboFlags` map directly onto the internal shortcut representation. A
copy of the user's real plist is committed as a test fixture at
`Tests/Fixtures/sizeup-user-config.plist`, giving a regression test that proves the exact
17-shortcut configuration survives import, including the clockwise quarter mapping.

## Spaces

No public API moves a window to another Space. Two viable approaches:

- **Drag simulation** — synthesize a title-bar mouse-down, fire the system Space
  shortcut, then mouse-up. Requires only Accessibility. Fragile for windows without
  title bars, and visibly flickers.
- **Private SkyLight/CGS calls** — better behavior, but undocumented, liable to break
  on any macOS update and exposed to future SIP tightening.

Decision: **defer Spaces to M4**, behind a `SpaceMover` protocol so either backend can
be substituted, starting with drag simulation. The feature also depends on the user's
Mission Control shortcuts being enabled; that state is detected by reading
`com.apple.symbolichotkeys`, and a warning appears in Preferences when they are off.

Until M4 lands, SizeUp stays installed alongside the replacement, with only its four
Space shortcuts still in use.

## Error handling

| Situation | Behavior |
|---|---|
| Accessibility permission missing | Onboarding window with deep link to the settings pane |
| No focused window | Do nothing, silently |
| Frontmost app on skip list | Do nothing. The hotkey is still consumed; Carbon cannot pass it through. Documented. |
| Accessibility write rejected | Read back the achieved frame, record it, do not retry in a loop |
| Hotkey registration failed | Error badge on the corresponding row in Preferences |

## Testing

- `Geometry` — halves, quarters, thirds, gap arithmetic, odd-pixel rounding, full cycle
  sequences. Uses injected `ScreenProvider`; needs no real displays.
- `Settings` — import correctness against the committed SizeUp plist fixture.
- `WindowKit` — coordinate conversion against synthetic multi-display layouts, including
  negative origins.
- Integration — a manual harness that spawns a TextEdit window and asserts real
  placement. Excluded from CI because it requires Accessibility permission.

## Build and install

```
make test     # swift test
make dev      # build, assemble .app, ad-hoc sign with fixed bundle ID, install to /Applications
```

`LSUIElement = 1` (no Dock icon). Launch at login via `SMAppService`.

## Milestones

- **M1** — `Geometry`, `WindowKit`, `Hotkeys`: halves, quarters, full screen, center,
  Snap Back. Usable daily.
- **M2** — Multi-display next/previous, status item menu, Preferences window, SizeUp
  import. The replacement now covers everything except Spaces; SizeUp is kept installed
  for those four shortcuts only.
- **M3** — Cycling, gaps, skip list.
- **M4** — Spaces, behind a feature flag.
