# M2 Manual Verification — Multi-Display Moves

Cross-display window placement cannot be verified automatically. It needs Accessibility permission, two real displays, and human eyes. The 123 automated tests cover the geometry and routing; this list covers the part only you can see.

**Before you start:**

- [ ] **Re-grant Accessibility permission.** Rebuilding the app changed its code hash, and because the bundle is ad-hoc signed macOS binds the grant to that hash. This was confirmed dropped during M2 development — the menu showed "Waiting for Accessibility permission…". Open **System Settings → Privacy & Security → Accessibility**, and if Sizeup2 is listed, toggle it **off and on again**; otherwise add `/Applications/Sizeup2.app`.
- [ ] Confirm the menu-bar icon shows no ⚠️ warning triangle.
- [ ] Have the external display connected.

## The new shortcuts

- [ ] **⌃⌥→** moves the focused window to the external display.
- [ ] **⌃⌥←** moves it back to the built-in display.
- [ ] Repeated **⌃⌥→** wraps around: with two displays it returns to the display it started on. A *tiled* window returns to exactly its original frame; a hand-positioned one may drift by up to a point per hop, because the proportional mapping floors each time. That drift is expected.
- [ ] These do **not** disturb the halves shortcuts, which are the same arrows plus ⌘. Press ⌃⌥⌘← and confirm you still get a left half rather than a display move.

## Exact retiling — the point of the milestone

- [ ] Tile a window to the **left half** (⌃⌥⌘←) on the built-in display, then press ⌃⌥→. It must be an **exact** left half of the external display: no gap at the left, top, or bottom edge.
- [ ] Tile a second window to the **right half** on the external display. The two must meet with no gap and no overlap.
- [ ] Tile a window to the **upper-right quarter** (⌃⌥⇧↑ — remember the mapping is clockwise, not spatial) and move it. It must stay flush with the **top and right** edges. This is the case proportional scaling gets wrong by one point, and it is the single most diagnostic check here.
- [ ] Full Screen (⌃⌥⌘M) then ⌃⌥→ fills the external display's usable area exactly — under the menu bar, above the Dock, not behind either.
- [ ] Center (⌃⌥⌘C) then ⌃⌥→ leaves the window the same size, centred on the new display.

## Behaviour that should NOT change

- [ ] **A display move must not resize the window.** Tile to a left half, then ⌃⌥→, and confirm it is still a left half rather than some other proportion.

  > **Note:** the shipped build configures a single size span, so pressing ⌃⌥⌘← repeatedly does **not** currently cycle through widths — you should see no size change, and that is correct, not a bug. Step preservation across a display move is therefore covered by automated tests only (`displayMoveReAppliesTheRetainedSpanNotTheNextOne`, verified by mutation testing to actually fail if the step is advanced or reset). This checklist item becomes manually observable once M3 makes the span list configurable.
- [ ] **Snap Back** (⌃⌥⌘/) after a display move returns the window to its original pre-tiling size *and* to its original display.
- [ ] A window you positioned **by hand** (never tiled) keeps roughly its relative position and size after ⌃⌥→ — it will not be pixel-exact, and that is correct.

## Edge cases

- [ ] With **only the built-in display** connected, ⌃⌥→ does nothing at all: no flicker, no resize, no movement.
- [ ] Move a window to the external display, then **unplug** that display. The window must remain reachable, and ⌃⌥← must bring it back rather than stranding it.
- [ ] Move a window that has a **minimum size** larger than the destination allows (some preference windows, Docker Desktop) and confirm it lands sensibly rather than half off-screen.
- [ ] Try it on a **full-screen-native** app window (one using macOS's own full-screen mode). Expect nothing to happen; confirm it does not corrupt the window.

## Menu and login item

- [ ] The menu lists **Next Display** and **Previous Display**, with ⌃⌥→ / ⌃⌥← shown as their tooltips.
- [ ] **With SizeUp still running**, quit and relaunch Sizeup2. Those two menu entries should read **"(claimed by another app)"** — not "(duplicate shortcut)", which would mean a bug in our own keymap instead. Quit SizeUp, relaunch Sizeup2, and confirm the suffix disappears.
- [ ] **Open at Login is expected to be GREYED OUT.** This was measured during development, not assumed: macOS reports `.notFound` for an ad-hoc-signed app whether it sits in `/Applications` or in a build directory, so the feature cannot work until the app is signed with a real identity. Hover it and confirm the tooltip names the *signature* as the reason, not the location. **Do not try to fix this by moving the app** — that was the original (wrong) guess and it does not help.
- [ ] To actually start Sizeup2 at login today, add it under **System Settings → General → Login Items**, which does not require a Developer ID. Confirm it comes back with working shortcuts after a reboot.

## If something is wrong

Note which check failed and what you saw instead. The most likely failure modes, in order:

1. **Window lands one point short of an edge** — the exact-retile path did not fire, so it fell back to proportional mapping. Means `retainedPlacement` returned nil, most likely because the app re-laid-out its window and drifted past the 2pt tolerance.
2. **Window changes size on a display move** — the cycle step advanced when it should have been preserved.
3. **Nothing happens at all** — Accessibility permission, or the shortcut is claimed by another app; check the menu for a reason suffix.
4. **Window moves to the wrong display** — display ordering. Displays are sequenced left-to-right by position, not by macOS's arrangement order, so a vertically stacked setup sequences bottom-to-top.
