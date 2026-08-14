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

> **Before you run Sizeup2 for the first time**, SizeUp is almost certainly
> already claiming the exact shortcuts Sizeup2 needs. Open SizeUp's
> preferences and **disable** its Halves, Quarters, Full Screen, Center, and
> Snap Back shortcuts, keeping only its four Spaces shortcuts (SizeUp's
> Spaces handling is why it stays installed at all in this milestone — see
> "Status" below). Two processes racing for the same global hotkey is not
> deterministic: whichever one wins can vary, and losing is silent unless
> you look for it. A ⚠️ warning-triangle icon in the menu bar (instead of
> the normal split-rectangle icon) means one or more shortcuts could not be
> claimed — open the menu to see which.
>
> **Launch at login is implemented but not currently usable.** The menu has an
> **Open at Login** item backed by `SMAppService`, but macOS will not register
> an *ad-hoc-signed* app as a login item, and this app is ad-hoc signed by
> design (see Distribution below). Measured on macOS 26, the service status is
> `.notFound` from `/Applications` as well as from a build directory — moving
> the app does not help. The menu item is therefore greyed out with a tooltip
> naming the real reason, rather than silently doing nothing.
>
> Until the app is signed with a real identity, start Sizeup2 by hand after a
> reboot, or add it under **System Settings → General → Login Items**, which
> does not require a Developer ID.

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

## Settings

Open **Settings…** from the menu-bar menu, or press ⌘, while the menu is open.

**Gaps.** "Between windows" is the space left between two tiled windows; "Screen edges" is the inset
from the edge of the usable screen area. Both default to 0, so out of the box windows tile flush, and
both are capped at 100 — a large enough gap would otherwise reduce a window to zero width.

**Size cycling.** Choose which fractions a repeated press cycles through: ½, ⅓, ⅔, ¼, ¾, applied in
that order. **Cycling is off by default** — only ½ is selected, so pressing ⌃⌥⌘← twice leaves the
window a left half, exactly as SizeUp behaved. Check a second size to turn cycling on. Moving a window
to another display deliberately does *not* advance the cycle.

**Skip list.** Applications Sizeup2 leaves alone entirely. Add them by name from a list of what is
running, rather than by typing bundle identifiers.

Settings are stored as JSON at `~/Library/Application Support/Sizeup2/settings.json`. The file is
written pretty-printed with sorted keys so it can be edited by hand, which is the way to reach a size
the Settings window does not offer — add e.g. `{ "columns": 5, "occupied": 2 }` to `cycle` for a 2/5
step. Hand-edited sizes are preserved when you use the Settings window, and it will tell you they are
there. A missing or corrupt file is not an error: the app starts on defaults rather than refusing to
run.

## Status

Milestones M1 to M4 are complete:

- **M1** — single-display placement: halves, quarters, full screen, centre, snap back, and a status-bar
  menu that mirrors every shortcut and names any shortcut another app has already claimed.
- **M2** — multi-display moves (`Next Display` / `Previous Display`). A window we tiled keeps its exact
  layout on arrival, because the placement is recomputed on the destination display rather than scaled;
  anything else is mapped proportionally.
- **M3** — settings, persistence, and a Preferences window, which is what finally makes gaps, size
  cycling, and the skip list reachable.
- **M4** — rebindable shortcuts, and importing them from an existing SizeUp installation.

Not yet implemented:

- **M5** — macOS Spaces (`Next Space` / `Previous Space`). Keep SizeUp installed for these until then.
  SizeUp's four Spaces shortcuts *do* import, but they cannot fire yet, and the import says so.

### Shortcuts

Every shortcut can be changed under **Settings → Shortcuts**, or cleared entirely if you need the key
for something else. Recording releases Sizeup2's global hotkeys for as long as the recorder is
listening — otherwise pressing the shortcut you want to replace would just perform its action, since a
registered hotkey is consumed before any application sees it.

If the shortcut you record is already used by another action, that action loses it and the window says
which one. Two actions cannot share a key: macOS would simply refuse the second one, silently and in an
order you cannot predict.

**Import Shortcuts from SizeUp…** in the menu reads `~/Library/Preferences/com.irradiatedsoftware.SizeUp.plist`
and adopts all seventeen of its bindings. The menu item is disabled if that file is not there.

Known not to work: **Open at Login**. It is implemented, but macOS will not register an ad-hoc-signed
app as a login item at any location. Add Sizeup2 under System Settings → General → Login Items instead.

## Development

```
swift test    # run the test suite
make build    # produce build/Sizeup2.app
make clean    # remove build artifacts
```
