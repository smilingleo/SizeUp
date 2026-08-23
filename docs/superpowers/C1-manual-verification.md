# C1 Manual Verification

A side-by-side pass against the installed Rust ClipShot, which is the
**behavioral oracle** for the Swift port. C1 delivers the rename, the capture
foundation, and the screenshot flow; this checklist covers the whole of it.

The unit tests (333 of them) already pin the *pure* logic — the crop math, the
state machine, the importer, the keymap, the model. What they cannot do is
put a window on a screen, so **this pass is the part a human runs**: real
permissions, a real Retina display, a real overlay.

## How to run

```
make dev
```

Builds an ad-hoc-signed `ClipShot.app` and installs it to `/Applications`,
**taking over the path the Rust ClipShot occupies** (the Swift executable is
`ClipShot`; `pkill -x ClipShot` will not touch the lowercase `clipshot`, so
the Rust app and the Swift app coexist until you quit one). Launch the
installed app; it appears as the ClipShot template icon in the menu bar.

> The Rust app is still the oracle for *behavior* (do the two look and act
> the same?). The Swift app is what you are verifying. Run them side by side.

Work through the seven areas below. Each lists the exact action, the expected
result, and (where it matters) what to compare against the Rust app.

---

## 1. Rename + settings migration (do this first)

- [ ] **Accessibility grant carries over.** On first launch the app does **not**
      re-prompt for Accessibility — the existing grant (bound to `com.lliu.sizeup2`)
      still works. A window action (⌃⌥⌘←) resizes a window with no prompt.
      If it *does* prompt, the rename changed the identifier and broke the grant —
      stop and check `Resources/Info.plist`.
- [ ] **The settings file migrated.** The old `~/Library/Application Support/Sizeup2/settings.json`
      is gone, and `~/Library/Application Support/ClipShot/settings.json` exists.
- [ ] **The hand-edited cycle survived.** Your two-span cycle (½ and ⅓, in that
      order) is exactly what the Shortcuts/Window tab shows. Open **Settings →
      Window** and confirm both ½ and ⅓ are ticked — a migration that dropped or
      reordered the cycle would show otherwise.
- [ ] **No re-grant of Screen Recording** is *expected* — see area 5; the Rust
      ClipShot's grant does **not** carry over (different bundle ID), so the
      Swift app will prompt once. That is documented and intended.
- [ ] **Shortcuts tab is pixel-identical to Sizeup2's** for the 15 window rows
      (same bindings, same order), now with 3 capture rows added above them.

## 2. Screenshot (the core C1 feature)

- [ ] **⌃⌘A** dims the **display under the cursor** (in a two-display setup, the
      overlay appears on the correct display, not always the main one).
- [ ] **The overlay is not upside down.** The dimmed screen matches the real
      screen (check something asymmetric — the Dock, the menu bar). A flipped
      view mirrors an `NSImage` unless it is drawn with the one-argument
      `draw(in:)`; when it mirrors, the crop is mirrored too, because the
      selection is taken in the coordinates you see. `orientationIsUpright`
      pins it, but eyeball it once.
- [ ] **Drag** draws a dashed selection; the complement is dimmed; a size badge
      shows the **pixel** dimensions (scale factor honored — on a 2× Retina
      display a 500-pt selection reads ~1000 px).
- [ ] **Esc** cancels — the overlay disappears and **nothing** is written to the
      clipboard. Confirm by pasting into Preview: no new image.
- [ ] **Enter** copies — paste into Preview and the image matches your selection
      **to the pixel** (the crop uses the backing scale; a mis-scaled crop would
      be ½ the size or offset).
- [ ] **⌘S in the overlay** opens the save panel, default name
      `clipshot-capture-YYYY-MM-DD_HH-mm-ss.png`, and writes a valid PNG.
- [ ] A **sub-5pt drag** (a plain click) produces nothing — no 1×1 image, no
      clipboard write.

**Compare to Rust:** take the same region in both apps; the crops should be
indistinguishable.

## 3. Menu

- [ ] **Capture section** is top-level: Screenshot ⌃⌘A, Record Screen ⌃⌘Z,
      Scroll Capture ⌃⌘S.
- [ ] **Three submenus**: `Window ▸` (halves / corners / full screen, center,
      snap back), `Display ▸` (next / previous), `Spaces ▸` (next / previous).
      Every one of the 15 window actions is reachable in two clicks.
- [ ] Each row still shows its shortcut, and the honest suffixes survive the
      move into submenus: `(no shortcut)` when unbound, `(…reason…)` when
      another app claimed the keys, `(unavailable on this macOS)` beside a Space
      item whose private API is absent.
- [ ] **Help** opens the docs site (`smilingleo.github.io/clipshot-docs`).
- [ ] **Quit ClipShot** (⌘Q) is labeled ClipShot, not Sizeup2.
- [ ] The SizeUp importer and "Open at Login" are **gone from the menu** (they
      moved to Settings → Shortcuts and → General in the redesign).

## 4. Settings (three tabs)

- [ ] **⌘, opens three tabs**: General / Window / Shortcuts.
- [ ] **General** — the Login toggle (greyed with the ad-hoc-signing tooltip,
      unchanged behavior); the **Accessibility** row shows "Granted" on this
      machine with an Open-System-Settings button; the **Screen Recording** row
      shows its real state. The two **capture toggles** (cursor, click ripples)
      are on by default and **persist across a relaunch**.
- [ ] The permission deep links open the **right** pane
      (`Privacy_Accessibility` / `Privacy_ScreenCapture`).
- [ ] **Shortcuts** — rebind ⌃⌘A to ⌃⌘K: Screenshot follows the rebind, and
      because ⌃⌘K is free the displacement message (if any) is accurate. The
      two import buttons show enabled/disabled + tooltip correctly for whether
      the SizeUp plist and ClipShot `config.ini` exist.
- [ ] **Import from SizeUp** and **Import from ClipShot** both do the
      confirm-then-report flow and replace all overrides, as stated in the
      confirm dialog.

## 5. Permissions (the clean-user path)

On a second user account, or after removing the app's Screen Recording TCC
entry (`tccutil reset ScreenCapture com.lliu.sizeup2`) and relaunching:

- [ ] The **first ⌃⌘A** shows the system **Screen Recording** prompt (once per
      launch). It does **not** prompt at app launch — only on a capture attempt.
- [ ] While Screen Recording is **ungranted**: ⌃⌘A shows the one-time alert
      (naming the pane, with an "Open System Settings" button) and aborts; the
      menu **still lists** the capture items.
- [ ] **Window actions work the whole time** — the two permissions do not
      cross-gate. With only Accessibility, the app is a full window manager.

## 6. Hotkey failure honesty

- [ ] Hand-edit `settings.json` to bind a capture action to a key another action
      already holds (e.g. Screenshot and Full Screen both on ⌃⌥⌘←): the menu
      shows the **claimed-by annotation** on the losing row, and the action
      doesn't double-fire.
- [ ] The status icon is the **warning triangle** only when registration itself
      fails — not for a mere conflict.

## 7. Window-manager regression (M1–M5 unchanged)

- [ ] Halves, quarters, full screen, center, snap back all behave exactly as
      before the merge.
- [ ] Multi-display tiling, Size cycling (½/⅓ repeat), gaps, the skip list, and
      Spaces all behave exactly as M5 left them. **Nothing** about window
      management changed in C1 — if any of these feels different, it is a bug.

---

## Recording and scroll capture: listed, not yet built

- [ ] **⌃⌘Z (Record Screen)** and **⌃⌘S (Scroll Capture)** are registered and
      listed, but selecting them (hotkey or menu) shows the one-time
      **"Coming in a later build"** alert and changes nothing. This is the
      honest-absence behavior — the key stays bound, the feature does not pretend
      to exist. (They become live in C3 and C5.)

---

## Done

When all boxes are ticked, C1 is done: the merged app is a daily driver for
both jobs minus annotation and recording. Then retire the superseded installs —
the doc and README say so explicitly:

- `/Applications/Sizeup2.app` — superseded by ClipShot (same bundle ID); uninstall.
- `/Applications/ClipShot.app` (the **Rust** one) — the Swift app now owns this
  path; the Rust build is the development oracle, not something you run daily.
  Delete it once you are satisfied C1 is solid. Its Screen Recording grant does
  **not** transfer to the Swift app (different bundle ID) — that is the one-time
  re-grant documented in the README.

`swift test` green (333), `swift build -c release` warning-free, and both lints
pass are the automated half; this pass is the human half.
