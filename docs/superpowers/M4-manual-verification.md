# M4 manual verification — shortcut rebinding and the SizeUp import

Everything below was checked by driving the live app with `osascript` and reading screenshots back,
except where it says otherwise. The items marked **only checkable by hand** are the ones automation
could not reach, and they are the ones worth your time.

## 0. Before anything else

- [ ] **Re-grant Accessibility.** The rebuild changed the ad-hoc code hash, so the grant is gone again.
      System Settings → Privacy & Security → Accessibility → toggle Sizeup2 off and on. Until you do,
      the menu's first item reads "Waiting for Accessibility permission…" and no shortcut works.

## 1. Nothing changed by default

This is the point of the milestone. If any of these fail, the rest does not matter.

- [ ] Delete `~/Library/Application Support/Sizeup2/settings.json`, relaunch, and confirm every
      shortcut still works exactly as it did: ⌃⌥⌘ arrows for halves, ⌃⌥⌘M full screen, ⌃⌥⌘C centre,
      ⌃⌥⌘/ snap back, ⌃⌥⇧ arrows for quarters, ⌃⌥→/← for displays.
- [ ] The quarters still use SizeUp's clockwise mapping: ⌃⌥⇧← upper **left**, ⌃⌥⇧↑ upper **right**,
      ⌃⌥⇧↓ lower **left**, ⌃⌥⇧→ lower **right**. This is deliberate and matches SizeUp. It is not a bug.
- [ ] Settings → Shortcuts lists 13 actions and shows those same keys.

## 2. Rebinding

- [ ] Record a new shortcut for Centre. It takes effect immediately — no relaunch.
- [ ] **The trap this milestone exists to avoid, and only checkable by hand.** Click Record on
      **Left Half** and press its *current* shortcut, ⌃⌥⌘←. It must be **recorded**, and the focused
      window must **not** move. If the window moves instead, the hotkeys were not suspended and the
      recorder is unusable for every shortcut that is already bound — which is nearly all of them.
- [ ] While recording, press a key with no modifier (say `K`). Nothing is recorded and recording
      continues. Then press Escape: recording cancels and the old shortcut is untouched.
- [ ] Record ⌃⌥⌘/ — Snap Back's shortcut — onto Centre. Snap Back must change to "None", its Clear
      button must grey out, and an **orange line at the top of the tab** must read
      "⌃⌥⌘/ was taken from Snap Back, which now has no shortcut."
- [ ] Press ⌃⌥⌘/ now: it centres the window and does *not* snap back. Only one action can hold a key.
- [ ] Clear a shortcut. The action stays listed in the status menu, marked "(no shortcut)", and
      clicking it there still performs the action — the menu is the only way to invoke it now.
- [ ] Restore Defaults returns everything, and empties `shortcutOverrides` in the settings file.

- [ ] **Only checkable by hand: closing the window mid-recording.** Click Record, then close the
      Settings window without pressing anything. Now press ⌃⌥⌘←. It must still work. If every shortcut
      is dead, `windowWillClose` failed to cancel recording and the app has silently released all of
      them until you relaunch.

## 3. Rebinding does not cost you anything else

- [ ] Record a shortcut, then go to the General tab and nudge **Between windows**. Reopen Shortcuts:
      your rebind is still there. (This was broken — the General tab predates shortcut overrides and
      rebuilt the whole settings file from the three fields it knew about, wiping every rebind whenever
      a gap changed.)
- [ ] And the reverse: set a gap and a skip-list entry, then record a shortcut. The gap and skip entry
      survive.

## 4. The import

- [ ] With SizeUp's plist present, **Import Shortcuts from SizeUp…** is enabled. It asks first, then
      reports "Imported 17 shortcuts" and notes that the Spaces ones do nothing yet.
- [ ] `settings.json` afterwards holds 17 overrides, and the four `space.*` entries are among them.
- [ ] Every non-Spaces shortcut behaves exactly as before the import — that plist is where these
      defaults came from, so a correct import is a no-op you cannot feel.
- [ ] Rename SizeUp's plist away, relaunch, and the menu item is **disabled** with a tooltip naming the
      path it looked in. Rename it back.

## 5. Odd keys

- [ ] Bind something to a function key, and to a punctuation key. The tab shows the real key name, not
      `?`. On a non-US layout it shows the key you actually pressed, not the US equivalent.
- [ ] Hand-edit `settings.json` to `"modifierFlags": 131072` (Shift only) for some action and relaunch.
      That override is **ignored** and the action keeps its default: a Shift-only global hotkey would
      steal a capital letter from the whole system.
- [ ] Hand-edit an override to `"action": "nonsense.thing"`. It is ignored, the app starts normally, and
      every real shortcut still works.

## 6. Known and deliberate

- **Open at Login is still greyed out.** Ad-hoc signing; unrelated to this milestone. Add Sizeup2 under
  System Settings → General → Login Items.
- **Binding a shortcut macOS already owns** (⌃↑, say) is recorded happily and then fails to register.
  The status item turns into a warning triangle and the menu item names the reason. The recorder does
  not refuse it up front, because there is no way to enumerate other applications' hotkeys.
- **The four Spaces shortcuts import but do nothing.** M5.
