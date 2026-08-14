# Sizeup2 M1 — Manual Verification Checklist

The branch `m1-window-management` is code-complete: 79 tests pass, `swift build -c release` is
warning-free, and every review finding is closed. What remains is the plan's Step 10 matrix, which
needs a human at the machine because Accessibility permission cannot be granted programmatically
and no automated test can observe a window actually moving.

The app is already built and installed at `/Applications/Sizeup2.app` and is running.

## Before you start

1. **Grant Accessibility permission.** System Settings → Privacy & Security → Accessibility → add
   or enable **Sizeup2**. The app is already polling, so it will pick up the grant within about a
   second — no relaunch needed. The bundle id is pinned to `com.lliu.sizeup2` forever, so this
   grant survives every future rebuild.

2. **Disable SizeUp's overlapping shortcuts.** SizeUp claims the same ⌃⌥⌘ and ⌃⌥⇧ combinations.
   In SizeUp's preferences, disable **Halves, Quarters, Full Screen, Center, and Snap Back**, and
   keep only its four Spaces shortcuts (those stay with SizeUp until M4).
   If you skip this, expect the menu-bar icon to be a ⚠️ warning triangle — that is the app
   correctly telling you a shortcut could not be claimed. After disabling them in SizeUp,
   **relaunch Sizeup2** so it can claim them.

## Already verified automatically (no action needed)

- [x] Bundle builds clean from scratch; `codesign -dv` → `Identifier=com.lliu.sizeup2`, `Signature=adhoc`
- [x] `Info.plist`: `LSUIElement=true`, `LSMinimumSystemVersion=14.0`, correct bundle id
- [x] App launches without Accessibility permission and does **not** crash
- [x] Permission poll does not spin hot — 0.0% CPU over 27s, no crash reports

## The 13 checks

Frame math, cycle detection, and the coordinate conversion are all covered by unit tests. These
checks exist to catch what tests structurally cannot: real apps behaving unlike the test fakes.

- [ ] **1. Halves.** ⌃⌥⌘← / → / ↑ / ↓ each tile the focused window to that half.
- [ ] **2. Size cycling.** Press ⌃⌥⌘← three times. Width should cycle 1/2 → 2/3 → 1/3 and wrap.
- [ ] **3. Cycle chain breaks on manual move.** Tile left, then drag the window by hand, then press
      ⌃⌥⌘← again. It must return to the **first** size (1/2), not continue the cycle.
- [ ] **4. Quarters — the clockwise mapping.** With ⌃⌥⇧: ← = Upper Left, **↑ = Upper Right**,
      **↓ = Lower Left**, → = Lower Right. This is deliberately *not* spatial; it is SizeUp's
      default and your muscle memory. If ↑ sends the window upper-*left*, that is a bug.
- [ ] **5. Full Screen.** ⌃⌥⌘**M** (M for maximize, not F).
- [ ] **6. Center.** ⌃⌥⌘C centers without changing the window's size.
- [ ] **7. Dock and menu bar clearance.** A full-screened window must not slide under the menu bar
      or behind the Dock. Then move the Dock to another edge and re-check.
- [ ] **8. Snap Back exactness.** Note a window's position, tile it, tile it again, tile a third
      time, then press ⌃⌥⌘**/**. It must return to the **original** position — not merely undo the
      last tile. This is the check most likely to expose a real-world app that settles its own
      frame a fraction of a point off; the tolerance comparison exists for exactly that.
- [ ] **9. External display, negative Y.** ⚠️ *Highest-risk item.* Your external monitor sits at
      Cocoa y = -838, so a sign error in the AX conversion shows up here and nowhere else. Tile
      halves and quarters on the external display and confirm they land correctly, not offset
      vertically by a display height.
- [ ] **10. Snap Back after unplugging.** Tile a window on the external display, unplug it, then
      press ⌃⌥⌘/. The window must land somewhere **visible** on the built-in display, not at
      coordinates that no longer exist.
- [ ] **11. Xcode minimum width.** Xcode refuses to go narrower than its minimum. Tile it to a
      third-width and press again — cycling must keep working rather than getting stuck, because
      the store records the frame Xcode *accepted*, not the one requested.
- [ ] **12. Menu actions target the right app.** Click into TextEdit, then click the menu-bar icon
      and choose "Left Half". **TextEdit's** window must move. (This was a real bug: clicking the
      menu activates Sizeup2, so the app used to target itself and do nothing.)
- [ ] **13. First press after launch.** Quit Sizeup2, relaunch it, and press ⌃⌥⌘← **without
      switching apps first**. It must work immediately. (Also a real bug once — the tracker started
      empty, so you had to Cmd-Tab away and back before anything worked.)

## Two extra checks worth doing

- [ ] **Two windows of the same app.** Open two TextEdit windows. Tile window A, then press Snap
      Back while window B is focused. Nothing should happen to either window. If B jumps, window
      identity is colliding and cycle state is leaking between windows.
- [ ] **Quit.** The menu's "Quit Sizeup2" must actually quit it. This is an `LSUIElement` app, so
      without a working Quit item the only way to stop it is `kill`.

## If something fails

Report which numbered item, what you expected, and what happened. Items 8, 9, and 11 are the ones
where a real-world app is most likely to behave unlike the test fakes, so a failure there is
informative rather than embarrassing.

## Known gaps in M1 (by design, not bugs)

- Next/previous **display** moves — M2
- Preferences UI; gaps, cycle sizes, and the skip list are wired but not yet configurable — M3
- **Spaces** moves — M4. Keep SizeUp installed for its four Spaces shortcuts until then.
- **Launch at login** is not implemented; start Sizeup2 by hand after a reboot.
