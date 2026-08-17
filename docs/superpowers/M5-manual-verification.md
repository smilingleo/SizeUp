# M5 manual verification — Spaces

The parts that could be verified without Accessibility permission were verified: the private API resolves,
a window really moves between Spaces, following really switches and restores, and the menu lists fifteen
actions. What could not be automated is the part that runs through a real focused window, because the app
needs Accessibility for that and the grant is lost on every rebuild.

## 0. Before anything else

- [ ] **Re-grant Accessibility.** System Settings → Privacy & Security → Accessibility → toggle Sizeup2
      off and on. The rebuild changed the ad-hoc code hash. Until then the menu's first item reads
      "Waiting for Accessibility permission…" and nothing works.
- [ ] You need **at least two Spaces on one display**. Mission Control (⌃↑) → hover the top strip → `+`.
      With one Space there is nowhere to go and the shortcut correctly does nothing.

## 1. Nothing changed by default

- [ ] Every existing shortcut still behaves exactly as before: ⌃⌥⌘ arrows, ⌃⌥⌘M, ⌃⌥⌘C, ⌃⌥⌘/, ⌃⌥⇧ arrows
      for the clockwise quarters, ⌃⌥→/← for displays.
- [ ] The menu lists **15** actions, ending with Next Space and Previous Space.

## 2. Moving a window

- [ ] Focus a window on Space 1 and press **⌃⌘→**. The window moves to Space 2 *and the screen follows it*,
      so you are looking at the window on its new Space. This is SizeUp's behaviour and the default.
- [ ] Press **⌃⌘←** to bring it back.
- [ ] Press ⌃⌘→ repeatedly. It **wraps** from the last Space to the first. Without wrapping it would
      simply stop, which is indistinguishable from broken.
- [ ] On a display with exactly one Space, ⌃⌘→ does nothing at all — no flicker, no move.

## 3. Following, and turning it off

- [ ] Settings → General → Spaces → turn **Follow the window to its new Space** off.
- [ ] Press ⌃⌘→. The window leaves and **you stay put**. This looks exactly like the window closing —
      which is why following is on by default, and why the setting's own description says so.
- [ ] Switch to the next Space by hand (⌃→) and confirm the window is there.
- [ ] Turn following back on.

## 4. Interaction with everything else

- [ ] **The important one.** Put a window on the left half (⌃⌥⌘←), move it to another Space (⌃⌘→), then
      press Snap Back (⌃⌥⌘/). It must return to the size and position it had *before you tiled it* — a
      space move must not count as a placement.
- [ ] With size cycling on (Settings → General → tick ⅓ as well as ½): press ⌃⌥⌘← once, move the window
      to another Space, then press ⌃⌥⌘← again. It goes to the **second** size in your cycle, not back to
      the first — moving a window between Spaces does not disturb where you are in the cycle.
- [ ] Add an app to the skip list, then press ⌃⌘→ on one of its windows. Nothing happens, as with every
      other action.
- [ ] Rebind Next Space to something else under Settings → Shortcuts. The new key works and the old one
      does not.

## 5. Above and below are gone, deliberately

SizeUp binds ⌃⌘↑ and ⌃⌘↓ to "Space Above" and "Space Below". macOS has arranged Spaces in a single
horizontal strip per display since Lion, so there is no Space above or below anything. **Those two
shortcuts have not done anything in your SizeUp for over a decade.**

- [ ] Run **Import Shortcuts from SizeUp…**. It reports **15 imported** and names **2 skipped**: Space
      Above and Space Below. They are not imported as dead keys, and they are not quietly remapped onto
      next and previous either — guessing a direction whose failure mode is a window landing on a Space
      you did not ask for is worse than not having the key.
- [ ] After importing, ⌃⌘↑ and ⌃⌘↓ do nothing. They are free for you to use for something else.

## 6. Full-screen apps

The one that a review caught and the plan had missed. macOS puts a full-screen application's Space **in
the strip** between the user's Spaces — measured on this machine, making TextEdit full-screen turned the
strip `[1, 3]` into `[1, 398, 3]`.

- [ ] Put an app into full-screen (green button or ⌃⌘F). Focus a window on Space 1 and press **⌃⌘→**.
      The window must go to your *next ordinary Space*, **not** into the full-screen app. If it vanishes
      behind the full-screen window, this regressed.
- [ ] Focus the full-screen app itself and press ⌃⌘→. Nothing happens — a window inside a full-screen
      Space is left alone.

## 7. Robustness

- [ ] Hand-edit `~/Library/Application Support/Sizeup2/settings.json` to
      `{"followsWindowToSpace": "yes please"}` and relaunch. The app starts and follows by default.
- [ ] Move a window to another Space, then close it, then press ⌃⌘→ with nothing focused. Nothing happens.

## 8. Known and deliberate

- **Spaces use private system interfaces.** There is no public API for this; every window manager that
  does it uses the same SkyLight functions. If a future macOS removes them, the two Spaces shortcuts stop
  working, the menu says **"(unavailable on this macOS)"** next to them, and the other thirteen actions
  are unaffected. That degradation is the reason the private API is confined to one target.
- **A failing move can take about 50ms** of main-thread time, because the move is confirmed by polling the
  window server rather than trusted. A successful move is confirmed on the first read.
- **Above/Below cannot be implemented.** See section 5.
- **Open at Login is still greyed out.** Ad-hoc signing, unrelated.

## 9. When this passes

SizeUp can be uninstalled. It was kept installed through M1–M4 only for its four Spaces shortcuts, two of
which turned out not to work at all.
