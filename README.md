# Sizeup2

A menu-bar window manager for macOS, replacing the unmaintained SizeUp.
`Sizeup2` uses the Accessibility API and a handful of global keyboard
shortcuts to move and resize the focused window into halves, quarters,
full screen, or back to where it started.

## Default shortcuts

These match the user's live SizeUp preferences exactly — muscle memory
built over thousands of window moves is the specification, not a
starting point. See `Sources/Core/DefaultKeymap.swift`.

| Shortcut | Action |
|---|---|
| ⌃⌥⌘← | Left Half |
| ⌃⌥⌘→ | Right Half |
| ⌃⌥⌘↑ | Top Half |
| ⌃⌥⌘↓ | Bottom Half |
| ⌃⌥⌘M | Full Screen |
| ⌃⌥⌘C | Center |
| ⌃⌥⌘/ | Snap Back (undo the last move) |
| ⌃⌥⇧← | Upper Left |
| ⌃⌥⇧↑ | Upper Right |
| ⌃⌥⇧↓ | Lower Left |
| ⌃⌥⇧→ | Lower Right |

The quarter bindings follow SizeUp's default arrow assignment, which runs
**clockwise from the left arrow** rather than mapping arrows to corners
spatially: left = upper left, up = upper right, down = lower left, right =
lower right. This looks like a bug. It is not — it is how the arrows were
originally laid out in SizeUp, and changing it would break existing muscle
memory.

## Installing

```
make dev
```

This builds an ad-hoc signed `Sizeup2.app`, installs it to `/Applications`,
and launches it. `make build` alone produces `build/Sizeup2.app` without
installing it. `make run` builds and runs from `build/` without touching
`/Applications`.

## Accessibility permission

Sizeup2 needs Accessibility permission to read and move other applications'
windows. macOS cannot grant this programmatically: on first launch the app
prompts once, then polls once a second until the permission is granted. The
menu bar shows "Waiting for Accessibility permission…" in the meantime, and
starts working within a second of the grant, no relaunch required.

Grant it under **System Settings → Privacy & Security → Accessibility**.

The app's bundle identifier is fixed at `com.lliu.sizeup2` and must never
change — the Accessibility grant is tied to that identifier, so changing it
silently breaks the app and forces the user to re-grant permission. The
build script ad-hoc signs with this identifier pinned so the grant survives
rebuilds.

## Status

This is milestone M1: single-display window placement, halves, quarters,
full screen, center, and snap back, plus a status-bar menu that mirrors
every shortcut and flags any shortcut another app has already claimed.

Not yet implemented (future milestones):
- Multi-display cycling (`Next Display` / `Previous Display`)
- macOS Spaces (`Next Space` / `Other Space`)
- User-configurable keymaps and preferences
- Importing settings from an existing SizeUp installation
- Gaps between windows and multi-span cycling beyond a single half

## Development

```
swift test    # run the test suite
make build    # produce build/Sizeup2.app
make clean    # remove build artifacts
```
