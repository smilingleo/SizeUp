# Deferred Findings — carried out of M1, updated after M2, M3 and M4

Every item below was found by review during M1 and deliberately **not** fixed then. The M1 execution
ledger lives in `.superpowers/`, which is gitignored, so this file is the durable record. Each item
has a triage decision from the broad final review.

Items judged "fix now" during M1 were fixed in the two post-review fix waves and are **not** listed
here. What follows is only what was consciously left.

## Closed in M2

- **`ScreenInfo.id` is an array index, not a stable display identity.** Now a `CGDirectDisplayID`
  from `deviceDescription["NSScreenNumber"]`, with a synthetic fallback that keeps a missing
  screen number from aliasing two displays. (The fallback is unlikely-to-collide, not
  provably-collision-free: real display ids are opaque `UInt32`s in the tens of millions. The
  original comment overclaimed this and has been corrected.) Ordering is a separate `spatiallyOrdered(_:)`
  helper sorting by `frame.minX`, then `minY`, tie-broken by id. Confirmed on real hardware that the
  built-in display reports id 4 and the external id 1 — so ids are neither array indices nor in
  spatial order, which makes the sort load-bearing rather than cosmetic.
- **`registrationFailures` does not say *why* a shortcut failed.** Now `[RegistrationFailure]`, each
  carrying `.alreadyClaimedByThisApp`, `.rejectedBySystem(OSStatus)`, or `.handlerInstallFailed`, and
  the menu names the reason instead of saying "unavailable". The `OSStatus` is also logged, since
  `explanation` deliberately omits it.
- **`DefaultKeymap.title(for:)` has catch-all `.display` / `.space` arms.** All eight direction cases
  are now spelled out, so a future `Direction` case fails to compile rather than acquiring a wrong
  label.
- **Launch at login is not implemented.** Now an "Open at Login" menu item over
  `SMAppService.mainApp`, disabled with a tooltip when the system will not register the bundle.
  **Measured caveat:** it does not currently work at all, because macOS refuses to register an
  ad-hoc-signed app as a login item — `status` is `.notFound` (raw 3) from `/Applications` as well as
  from a build directory. The implementation is correct and fails visibly instead of silently, but
  the feature is unreachable until the app has a real signing identity. This is a direct consequence
  of the project's ad-hoc-signing decision, so it belongs with the open-sourcing work, not with a
  bug fix. Fixing this exposed a second bug of M1's own kind: `NSMenu.autoenablesItems` defaults to
  true, so the manual `isEnabled = false` was silently discarded and the item stayed clickable.
  Verified through accessibility scripting rather than by reading the code.

## Still open for M2's successors

**Display-overlap tie-breaking is undocumented.**
`Sources/Core/ActionRouter.swift` — `screen(containing:)` keeps the largest `frame`-area overlap, so
a window 51% on display B is treated as being on B and "Next Display" moves it past the display the
user perceives it on. Now genuinely exercised by display moves, but still has no dedicated test, and
only becomes visible with three or more displays. Left open deliberately: the two-display case that
matters daily is unaffected.

**`keyName`'s `"?"` fallback is untested and silently meaningless.**
`Sources/Hotkeys/Shortcut.swift` — unchanged in M2, because nothing yet lets the user bind an
arbitrary key. It becomes user-visible the moment M3's preferences do, at which point use
`TISCopyCurrentKeyboardLayoutInputSource` / `UCKeyTranslate` rather than growing the switch.

**`record`'s implicit cycle advance does not check `action.cycles`.**
`Sources/Core/WindowStateStore.swift` — pressing a quarter shortcut twice stores `step = 1` even
though quarters do not cycle. Harmless only because `targetFrame` ignores `span` for quarters,
centre, and full screen. M2's `retiled` is the first code to read a stored step back, so the
assumption is now load-bearing and should be tightened when a second reader appears.

## Closed in M3

- **`Span.init` uses `precondition`, so bad user config would crash.** Configuration no longer reaches
  it: `SpanSetting.resolved` validates `columns` and `occupied` and returns nil, so a typo in the
  settings file yields a dropped cycle step rather than a trap. Pinned by
  `aZeroColumnSpanIsRejectedRatherThanTrapping`.
- **`ActionRouter` coerces an empty `spans` array to `[.half]`.** Still there, but no longer
  load-bearing: `Settings.resolvedCycle` falls back to `[.half]` before the router is constructed, so
  the router's coercion is now belt-and-braces rather than the only defence.
- **`WindowStateStore` capacity may be too small.** Raised 50 → 200. The existing capacity test passed
  an explicit `capacity: 2`, so the *default* was untested; `theDefaultCapacityHoldsFarMoreWindowsThanAnyoneOpens`
  now pins it and fails if it returns to 50.

## Deferred out of M3

**`proportionalFrame` ignores gaps — now a real inconsistency, not a hypothetical.**
`Sources/Geometry/ProportionalFrame.swift` — carried from M2, where gaps were unreachable and this
could not be observed. Now that gaps are configurable, a hand-positioned window moved between displays
lands flush while a tiled one is inset. Fix by insetting the destination visible frame by `outer`
before mapping. Left open because it needs a decision the plan did not make: whether an untiled window
should be gapped at all, given we do not know it was ever meant to touch an edge.

**The gap cap of 100 is a judgement, not a derivation — and it does NOT prevent degenerate windows.**
`Sources/Config/Settings.swift` — an earlier version of this document claimed the cap closed the
zero-size hazard. That was false, and it was load-bearing, because it was the stated reason for leaving
`isSafeToApply` permissive. `inner: 100` is a value the Settings window itself offers, and a 12-column
span is one the validator accepts; together, on an ordinary 1080p display, they produce a **zero-height**
bottom half. The claim only ever checked two columns.

Closed properly instead of re-argued: `targetFrame` now returns nil for a degenerate result, and
`isSafeToApply` requires a strictly positive size. Both are tested
(`aGapWideEnoughToConsumeTheAxisYieldsNoPlacement`, `aZeroSizeRectIsRefused`). What remains deferred is
only the cap itself: 100 is still an arbitrary number, and a user who wants a 150pt gap on a 6K display
cannot have one.

**The skip list also suppresses Snap Back.**
`Sources/Core/ActionRouter.swift` — the skip check is the first thing `perform` does, so adding an app
to the skip list makes any window we previously moved unrestorable. Defensible as "skipped means hands
off entirely", and left as-is deliberately, but it is a surprise worth documenting rather than
discovering.

**The skip list matches bundle identifiers exactly, with no wildcards.**
Adequate for the stated use, but there is no way to skip, say, every JetBrains IDE without listing each.

## Closed in M4

**`keyName`'s `"?"` fallback is untested and silently meaningless.** — closed.
Key names now come from the active keyboard layout via `UCKeyTranslate`, with a static table for the
keys layouts misreport. The fallback is `"Key N"`, which at least says which key it could not name;
`"?"` was indistinguishable from a key that really is `?`.

**Shortcuts were compile-time literals.** — closed. Every action is rebindable and can be unbound.

**Spaces was expected to need a wider `WindowHandle` for drag simulation.** — closed, and the premise
was wrong. Measured, not reasoned about: `_AXUIElementGetWindow` yields a real `CGWindowID` from an
`AXUIElement` in one `dlsym`, and `SLSMoveWindowsToManagedSpace` moves a window with SIP enabled and no
scripting addition. No drag, no title-bar point, no screen coordinates. The probes are kept in
`.superpowers/sdd/2026-08-14-sizeup2-m4/`.

## Deferred out of M4

**The import writes overrides for actions whose bindings already equal the defaults.**
`Sources/Config/SizeUpImport.swift` — importing the author's own plist produces seventeen overrides, of
which thirteen are byte-identical to what `DefaultKeymap` already ships. Harmless, and arguably correct
since the user explicitly asked for SizeUp's bindings, but it means a future release that improves a
default will not reach anyone who imported. Filtering would require `Config` to know `DefaultKeymap`,
which the layering forbids; the alternative is to filter in `App`, untested.

**`Shortcut` canonicalises modifier flags, so a settings file can round-trip to a different value.**
`Sources/Hotkeys/Shortcut.swift` — a hand-edited `"modifierFlags": 1835049` is loaded, canonicalised to
1835008, and re-persisted as 1835008. Correct, and the only way the type can be compared reliably, but
it does mean the file is not always byte-stable across a load/save cycle.

**A recorded shortcut is not checked against the shortcuts of *other* applications.**
`Sources/App/ShortcutsView.swift` — the recorder prevents Sizeup2 colliding with itself, but binding
something macOS already owns (⌃↑ for Mission Control, say) records happily and then fails at
registration. `HotkeyManager.registrationFailures` reports it in the status menu afterwards, so it is
visible, but the recorder could refuse it up front. There is no API to enumerate other apps' hotkeys, so
this would mean a hardcoded list of system shortcuts.

**The Shortcuts tab has no automated coverage.**
The decision logic is in `KeymapResolver` and tested; the view, the event monitor, and the
suspend/resume pairing are not, in line with the rest of `App`. The suspend/resume pairing in particular
is only verifiable by hand, and its failure mode — every shortcut silently released — is nasty. It is on
the M4 manual checklist.

## Before open-sourcing

**The `swift-testing` package dependency will break CI on runners that have Xcode.**
`Package.swift` — this machine has Command Line Tools only, so neither the bundled `Testing` module
nor `XCTest` is importable, and the SPM package is the only way to run tests. On a runner *with*
Xcode the toolchain also provides `Testing`, which will conflict. Gate the dependency or document a
flag before publishing.

## Accepted as-is (rationale recorded so it is not re-litigated)

- **`CFGetTypeID` + `unsafeDowncast` appears twice** (`AXWindow.swift`, `AXWindowProvider.swift`) for
  two different CF types. Both correct. Extract a shared generic helper only if a third appears.
- **`Tests/WindowKitTests` and `Tests/CoreTests` each define their own window fake.** Still true ACROSS targets. Within `CoreTests`, M2 merged two same-named copies that had already diverged (one echoed the requested frame, one simulated a minimum size) into `Tests/CoreTests/RouterFixtures.swift`. Swift test
  targets cannot share helpers without a separate support target, which is not worth it for two
  small fakes. **Do not extract these** — the duplication is deliberate.
- **Raw modifier integers (`1835008`, `917504`) appear in both `DefaultKeymap` and its test.** The
  restatement is deliberate: the test independently pins the value rather than importing the
  constant it is meant to verify.
- **No `isTerminated` check on the tracked application.** Safe, but by Foundation's behavior rather
  than by this code: `NSRunningApplication.processIdentifier` returns `-1` after termination, so
  `AXUIElementCreateApplication(-1)` fails rather than hitting a recycled pid. Documented at the
  point of use. **A future maintainer who caches a bare `pid_t` instead of the live object loses
  this guarantee.**
- **The Carbon callback firing path has no automated test.** Synthetic key events are not worth the
  harness; covered by the manual verification matrix instead.
- **`trailingExtent`'s full-axis fallback is untested**, and the quarters test proves exact tiling
  without separately asserting containment in `visibleFrame`. Both are implied by existing
  assertions.

## The untested surface, stated honestly

M1 ships 79 passing tests, weighted toward the pure logic most likely to be subtly wrong (exact
tiling, odd pixel counts, negative-origin displays, cycle-reset semantics, LRU eviction). But the
untested surface is also the surface most likely to break:

- `AXWindow`'s position/size/position write sequence and read-back has **no automated coverage**.
  The test fakes model a *cooperative* window — one that clamps size, honors position exactly, and
  responds synchronously. Real failure modes are windows that do not behave like the fake, so the
  tests are structurally incapable of finding them.
- `AXWindowProvider.focusedWindow()` is untested. That is how the frontmost-app/menu bug survived
  nine per-task reviews.
- `AppDelegate` has no tests, and it holds the permission state machine, the menu, and the second
  entry point into the router.

The manual matrix in `M1-manual-verification.md` is the substitute for all of this, and it has been
run and passed. Cheap additions worth making if this layer ever misbehaves: a fake window that
returns a frame a fraction of a point off the request (proving the tolerance comparison), and a
store test that a false-negative chain check does not clobber `originalFrame`.

## Added by M2

- **`LaunchAtLogin` has no automated coverage.** `SMAppService` talks to a system daemon and cannot
  be exercised from `swift test`. Its behaviour is pinned by the M2 manual checklist and by one
  runtime check through accessibility scripting, not by a unit test.
- **`proportionalFrame`'s exact full-frame round-trip assumes integral display dimensions.**
  `relativeWidth` is exactly `1.0` when the frame equals the source visible frame, so the multiply is
  exact — but the subsequent floor truncates if a destination `visibleFrame` dimension is itself
  fractional. macOS points-space visible frames are conventionally whole numbers, so this is safe in
  practice; the assumption is stated in the doc comment rather than enforced.
- **`Action.isPlacement` is defence-in-depth, not load-bearing.** Mutation testing showed that
  removing the check in `ActionRouter.retiled` changes no behaviour, because `targetFrame` already
  returns nil for every non-placement action. It is kept because it states the intent at the point of
  the decision, and is documented as such so a future reader does not assume it is doing work.
- **`proportionalFrame` ignores `gaps` while the exact-retile path applies them.** Moot today because
  gaps default to zero and are not yet configurable. The moment M3 ships gaps, a hand-positioned
  window moved between displays will sit flush while a tiled one is inset — visibly inconsistent.
  Fix when gaps become reachable.
- **`ActionRouter.perform` reads `screens.screens` twice per display move**, once inside
  `screen(containing:)` and once for the neighbour list. Benign (a display vanishing between the two
  reads yields nil and a no-op) but a single local snapshot would be one line and strictly better.
- **Mirrored displays can report the same `NSScreenNumber` for two `NSScreen` entries.** In that case
  the `firstIndex(where: { $0.id == current.id })` lookup picks whichever comes first. Harmless
  because mirrored displays share a frame, so either answer places the window identically.
