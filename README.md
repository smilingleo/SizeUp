# ClipShot

A menu-bar app for macOS that does two jobs: it **manages windows** (the former
Sizeup2 — halves, quarters, full screen, center, multi-display, Spaces, snap
back) and it **captures the screen** (region screenshots, and — landing in
later builds — screen recording and scroll capture). Both run on global
keyboard shortcuts.

It was built from Sizeup2, the Swift replacement for the unmaintained SizeUp,
with the ClipShot capture suite merged in and rewritten in Swift. The name
changed; the bundle identifier did not.

## Permissions

ClipShot uses two independent macOS permissions, each gating only its own side:

| Permission | Needed for | How it is asked |
|---|---|---|
| **Accessibility** | Every window action | Prompted on first launch; the menu shows "Waiting for Accessibility permission…" until granted. |
| **Screen Recording** | Screenshot, recording, scroll capture | Prompted the first time you take a capture. |

They do not depend on each other: with only Accessibility you get the window
manager; with only Screen Recording you get the capture tool. Until a
permission is granted, its side simply does nothing and says so in the menu or
Settings → General (which has a row and a deep link for each).

Grant them under **System Settings → Privacy & Security → Accessibility** and
**… → Screen Recording**.

> **Bundle identifier.** The app is `ClipShot.app` but its identifier is
> `com.lliu.sizeup2`. That is deliberate: macOS binds the Accessibility grant
> to the *identifier*, so changing it would silently void the permission and
> force a re-grant on every rebuild. The name is the identity; the identifier
> is an implementation detail. Do not "clean" it up.

### Granting permissions only once

Run this **once per machine**, before your first build:

```sh
make signing-cert
```

Without it, every rebuild asks for Accessibility and Screen Recording all over
again. The reason is that macOS remembers a grant against the app's *designated
requirement*, and an ad-hoc signature has no certificate to name the app by, so
the requirement is a bare hash of the code itself:

```
designated => cdhash H"2b4ef50d…"
```

Change one byte, rebuild, and the hash changes with it — the grant is still in
the database, it just no longer matches anything. `make signing-cert` creates a
self-signed code-signing certificate, which moves the requirement to:

```
designated => identifier "com.lliu.sizeup2" and certificate leaf = H"a8b9b432…"
```

Both halves survive a rebuild, so the permission is granted once and stays.
The certificate does not need to be trusted by Gatekeeper for this to work; it
only has to exist and stay the same. `make build` picks it up automatically and
warns if it is missing.

**Switching an already-installed app over to it** needs one cleanup, because the
old grant is still keyed to the old ad-hoc hash and will look enabled while
doing nothing:

```sh
make dev                                        # install the newly signed build
tccutil reset Accessibility com.lliu.sizeup2    # drop the stale grant
tccutil reset ScreenCapture com.lliu.sizeup2
```

Then grant both once when asked. That order matters — reset *after* installing
the signed build, or you will re-grant the old one.

## Window management

`ClipShot` uses the Accessibility API and a handful of global keyboard
shortcuts to move and resize the focused window.

### Default shortcuts

These match the user's live SizeUp preferences exactly — muscle memory built
over thousands of window moves is the specification, not a starting point. See
`Sources/Core/DefaultKeymap.swift`.

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
| ⌃⌥← / → | Previous / Next Display |
| ⌃⌘← / → | Previous / Next Space |

The quarter bindings follow SizeUp's default arrow assignment, which runs
**clockwise from the left arrow** rather than mapping arrows to corners
spatially: left = upper left, up = upper right, down = lower left, right =
lower right. This looks like a bug. It is not — it is how the arrows were
originally laid out in SizeUp, and changing it would break existing muscle
memory.

The menu-bar menu lists every action (in **Window**, **Display**, and
**Spaces** submenus) with its current shortcut, and names any shortcut another
app has already claimed.

### Size cycling, gaps, and the skip list

- **Size cycling.** Choose which fractions a repeated press of a half shortcut
  cycles through: ½, ⅓, ⅔, ¼, ¾. **Cycling is off by default** — only ½ is
  selected, so pressing the shortcut twice leaves the window a half, exactly as
  SizeUp behaved.
- **Gaps.** Space between tiled windows and from the screen edge; both default
  to 0 (flush tiling) and both are capped at 100.
- **Skip list.** Applications ClipShot leaves alone entirely.
- **Spaces.** ⌃⌘←/→ move the focused window between Spaces, optionally
  following it there. This uses a private system interface that can break on a
  macOS update; the blast radius is those two shortcuts, and the menu says
  "(unavailable on this macOS)" beside them if it does.

## Screen capture

### Screenshot

`⌃⌘A` (or **Screenshot** in the menu) captures the display under the cursor and
shows a full-screen overlay. Drag to select a region; **Enter** (or the confirm
action) copies it to the clipboard, **Save** writes a PNG, and **Esc** cancels.

| Shortcut | Action |
|---|---|
| ⌃⌘A | Screenshot |
| ⌃⌘Z | Record Screen |
| ⌃⌘S | Scroll Capture |

**Recording** and **scroll capture** are listed in the menu and bound to
shortcuts but are not yet built; selecting them says so rather than doing
nothing silently. Annotation tools, the recording editor, and scroll stitching
land in the builds after this one.

## Installing

> **If you ran the old Sizeup2 or the standalone Rust ClipShot**, the new app
> replaces Sizeup2 in place (same bundle identifier, so your Accessibility
> grant carries over). The new app **migrates your existing settings file** on
> first launch, from `…/Application Support/Sizeup2/` to `…/ClipShot/` — your
> preferences and rebound shortcuts are preserved. The standalone Rust ClipShot
> is a separate bundle and is not affected; you can uninstall it once the
> capture features land here.

```
make dev
```

This builds an ad-hoc signed `ClipShot.app`, installs it to `/Applications`, and
launches it. `make build` alone produces `build/ClipShot.app` without
installing; `make run` builds and runs from `build/`.

## Settings

Open **Settings…** from the menu-bar menu (⌘,). Three tabs:

- **General** — launch at login, the two permission rows, and capture behavior.
- **Window** — gaps, size cycling, Spaces, and the skip list.
- **Shortcuts** — rebind or clear any of the 18 shortcuts, plus one-click
  import from SizeUp or the standalone ClipShot.

Settings are stored as JSON at `~/Library/Application Support/ClipShot/settings.json`
(pretty-printed, sorted keys, hand-editable). A missing or corrupt file is not
an error: the app starts on defaults rather than refusing to run.

## Development

```
make test     # run the test suite AND both lints
make build    # produce build/ClipShot.app
make clean    # remove build artifacts
```

Requires Swift 6 and macOS 14 or later.

> The test target depends on the `swift-testing` package. That is required on a
> machine with Command Line Tools but no Xcode, where the toolchain does not
> bundle the testing library; on a machine that does have Xcode it collides
> with the bundled copy. There is no configuration that works in both places,
> so CI must pick one and say which. See the house notes in the M1 plan.

Never write `#expect(x == false)` or any `==`/`!=` between Bools inside
`#expect` — on the pinned Swift Testing version those pass regardless of value.
`Scripts/lint-tests.py` catches it.
