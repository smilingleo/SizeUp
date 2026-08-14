# M3 Manual Verification — settings, gaps, cycling, skip list

Branch `m3-settings`. Run through this before merging to `main`.

## Before you start

**Re-grant Accessibility permission.** Every rebuild changes the code hash, and because the app is
ad-hoc signed macOS drops the grant. If the menu's first item reads "Waiting for Accessibility
permission…", nothing below will work.

System Settings → Privacy & Security → Accessibility → toggle **Sizeup2** off, then on. If it is not
listed, open the menu and click the permission item.

Settings live at `~/Library/Application Support/Sizeup2/settings.json`. It does not exist until you
change something — that is deliberate, and checked below.

---

## 1. Nothing changed by default — the most important section

This milestone must not alter a single existing behaviour. You have thousands of window moves of muscle
memory in these shortcuts, and every one of them must feel identical.

Start from a clean slate: quit Sizeup2, `rm -rf ~/Library/Application\ Support/Sizeup2`, relaunch.

- [ ] ⌃⌥⌘← / → / ↑ / ↓ still tile to exact halves, flush to the screen edges, **no gap anywhere**.
- [ ] Pressing ⌃⌥⌘← **twice** leaves the window exactly where it was. It must **not** resize.
      (Cycling is off by default and this is the check that proves it.)
- [ ] ⌃⌥⌘M full screen, ⌃⌥⌘C centre, ⌃⌥⌘/ Snap Back all behave as before.
- [ ] ⌃⌥⇧ + arrows still give SizeUp's clockwise quarters: ← upper **left**, ↑ upper **right**,
      ↓ lower **left**, → lower **right**.
- [ ] ⌃⌥→ / ← still move between displays, and a tiled window stays exactly tiled on arrival.
- [ ] **No settings file was created**, even though the app has been running: `ls ~/Library/Application\ Support/Sizeup2` should fail. Reading configuration is not a reason to write it.

If anything in this section fails, stop. Nothing else matters.

## 2. The Settings window opens and is usable

- [ ] The menu has **Settings…** with ⌘, next to it, and it is **not** greyed out.
- [ ] It opens **in front** of whatever you were using. (An `LSUIElement` app is not active, so this
      needs an explicit activate — worth confirming it happens.)
- [ ] Three sections with proper headings: **Gaps**, **Size cycling**, **Skip list**.
- [ ] Choosing Settings… again brings the **same** window forward rather than opening a second one.
- [ ] **Closing the window does not quit the app** — the menu-bar icon is still there and shortcuts
      still work.

## 3. Gaps

- [ ] Set **Between windows** to 10 and **Screen edges** to 10.
- [ ] ⌃⌥⌘← then ⌃⌥⌘→. The two windows are inset from the screen edges and separated from each other.
- [ ] **Measure the seam.** The space between the two windows should equal the "Between windows"
      value, and each window's outer edges should be inset by the "Screen edges" value. On the built-in
      display with 10/10 the left half should be at `(10, 10)` sized `1665 × 1840`.
- [ ] Quarters are gapped consistently — all four in the same screen without overlapping.
- [ ] Full screen (⌃⌥⌘M) respects the **outer** gap but has no inner seam.
- [ ] Neither stepper will go below 0 or above 100.

## 4. Size cycling

- [ ] Check **⅔** in addition to ½.
- [ ] ⌃⌥⌘← gives a left half. Press again → left two-thirds. Again → back to a half.
- [ ] Check **⅓** too. Now the cycle is half → two-thirds → one-third → half.
- [ ] **A display move must not advance the cycle.** Cycle a window to two-thirds, then ⌃⌥→. It should
      arrive as two-thirds on the other display, not as a half and not as one-third.
- [ ] Uncheck everything. This is allowed, not an error — behaviour falls back to halves only.
- [ ] With only ½ checked, the window shows text saying repeat presses will not resize. Confirm that
      matches what actually happens.

## 5. Skip list

- [ ] Click **Add Application…**. A list of your **running** apps appears, by name, with bundle
      identifiers underneath. Sizeup2 itself is not offered.
- [ ] Add one — a browser is a good choice. Focus that app and press ⌃⌥⌘←. **Nothing happens.**
- [ ] Every other app still responds normally.
- [ ] Press the **−** next to the entry. It is removed, and that app now responds to shortcuts again.
- [ ] Adding the same app twice does not create a duplicate entry.

## 6. Persistence

- [ ] Change several settings, quit Sizeup2 entirely, relaunch. Every setting is still as you left it,
      and windows behave accordingly.
- [ ] `cat ~/Library/Application\ Support/Sizeup2/settings.json` — it is readable, indented, with
      sorted keys.
- [ ] **Hand-edit it.** Quit the app, set `"gaps": { "inner": 30, "outer": 0 }`, relaunch, tile two
      halves. The 30pt seam is honoured.
- [ ] **Hand-edit a size the UI cannot offer**, e.g. add `{ "columns": 5, "occupied": 2 }` to `cycle`.
      Relaunch, open Settings: the Size cycling section tells you the file contains `2/5` and that it
      is kept. Toggle a checkbox and confirm `2/5` is **still in the file** afterwards — the UI must
      never silently discard a hand-edit.
- [ ] **Corrupt it deliberately**: `echo "{ nonsense" > …/settings.json`, relaunch. The app **starts
      normally on defaults**. It must not hang, crash, or refuse to launch.
- [ ] Put a huge value in — `"inner": 5000` — and relaunch. It is clamped to 100, and no window ends up
      zero-width or invisible.

## 7. Not expected to work

- [ ] **Open at Login is still greyed out.** macOS will not register an ad-hoc-signed app as a login
      item, from `/Applications` or anywhere else. Unchanged by this milestone. Use System Settings →
      General → Login Items instead.
- [ ] Shortcuts are still **not** rebindable — that is M4, along with importing your old SizeUp
      settings.
- [ ] The four Spaces shortcuts are still SizeUp's job. That is M5.

## If something is wrong

- Windows in one app do not move → is it in the skip list?
- Nothing moves at all → Accessibility permission; check the menu's first item.
- A shortcut does nothing → open the menu; a failed hotkey names its reason next to the item.
- Settings do not stick → look for a red message in the Settings window; a failed save reports itself
  there.
- Everything is subtly misplaced → check the gap values, then confirm you are reading `visibleFrame`
  expectations and not counting the menu bar.
