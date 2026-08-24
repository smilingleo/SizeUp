#!/usr/bin/env python3
"""Enforces the target layering, which until now existed only in prose.

Every milestone's task brief has restated these rules and every review has
checked them by hand. That worked, but it is exactly the kind of invariant that
holds until the one time nobody looks.

The rules and, more usefully, WHY each exists:

  Geometry   -- CoreGraphics only. It is the frame arithmetic, and it stays
                testable and reasonable precisely because it cannot see AppKit,
                a screen, a window, or a settings file.
  Config     -- no Carbon, no AppKit, no Core, no Hotkeys. It holds Codable DTOs
                for hand-editable JSON, and it DOES depend on Geometry: it must
                validate before constructing geometry types, which use
                `precondition` and would trap on a hand-edited file. That is why
                the DTOs are separate types, and why `Config` must not reach
                `Core` and start making routing decisions with them.
  Core       -- no Foundation, no Config. The routing logic. Keeping Foundation
                out is what keeps it honest about being pure decision logic over
                injected seams; concrete collaborators are assembled in App.
  No target   -- may touch private API. The Spaces feature was the only caller,
                and it was removed once macOS stopped honouring the SkyLight
                window-move: there is no longer a reason for any private symbol
                to be in the tree, so the allow-list is empty rather than
                pointed at a directory somebody could refill.

`App` is unconstrained: it is the executable, its job is to join things
together, and it is untestable by construction anyway.
"""

import pathlib
import re
import sys

FORBIDDEN_IMPORTS = {
    "Geometry": {"AppKit", "Foundation", "Carbon", "ApplicationServices", "Core",
                 "Config", "WindowKit", "Hotkeys"},
    "Config": {"AppKit", "Carbon", "Core", "Hotkeys", "WindowKit"},
    "Core": {"Foundation", "Config", "AppKit"},
    # Geometry included because `Hotkeys` declares NO dependencies in
    # Package.swift. The first version of this table omitted it, so the lint
    # permitted an import the build would have rejected -- encoding a rule from
    # prose instead of from Package.swift, which is exactly the mistake that makes
    # a lint worth less than the file it claims to guard.
    "Hotkeys": {"Core", "Config", "WindowKit", "Geometry"},
    "WindowKit": {"Core", "Config", "Hotkeys"},
    # The capture side of the merge. These are AppKit-free leaf targets (or the
    # one AppKit layer over them), so the rule for each is "no AppKit/Carbon and
    # no other project module" — the same shape that keeps Geometry and WindowKit
    # honest. Foundation/CoreGraphics/CoreText/ScreenCaptureKit are deliberately
    # NOT forbidden: they are how a target does real work without a window. The
    # `Stitching`/`Recording` rows land with those targets (C3/C5); the script
    # errors on a named directory that is absent, so a row cannot precede its
    # target.
    "Capture": {"AppKit", "Carbon", "ApplicationServices", "Geometry", "Config",
                "Core", "Hotkeys", "WindowKit", "Annotation",
                "OverlayUI", "VideoEdit"},
    "Annotation": {"AppKit", "Carbon", "ApplicationServices", "Geometry", "Config",
                   "Core", "Hotkeys", "WindowKit", "Capture",
                   "OverlayUI", "VideoEdit"},
    # The recording editor. Allowed both `Annotation` and `Capture` -- it is the
    # first target that needs the renderer and the codec at once, and keeping
    # video export here is what stops `App` from growing it. Still AppKit-free,
    # so the timeline and frame math stay testable without a screen.
    "VideoEdit": {"AppKit", "Carbon", "ApplicationServices", "Geometry", "Config",
                  "Core", "Hotkeys", "WindowKit", "OverlayUI"},
    # The one AppKit layer. It may import AppKit and the two targets it sits on;
    # nothing else (no Carbon, no the window-manager modules).
    "OverlayUI": {"Carbon", "ApplicationServices", "Geometry", "Config", "Core",
                  "Hotkeys", "WindowKit"},
}

# Private-API entry points, now banned outright: the Spaces feature was the only
# caller and it is gone, so the cheapest way to keep it that way is an empty
# allow-list.
# `dlopen`/`dlsym` (looking a symbol up by name at runtime, which is how you
# reach something with no header) and underscore-prefixed AX symbols.
#
# NOT `unsafeBitCast`, which was the first version of this check and is wrong:
# `Hotkeys/KeyName.swift` uses it to bridge a `TISGetInputSourceProperty` result
# to `CFData`, which is entirely public API. Flagging it made the lint cry wolf
# about correct code on its first run, and a lint nobody believes is worse than
# no lint.
# `@_silgen_name` and `CFBundleGetFunctionPointerForName` are here because a
# reviewer reached a private symbol from `Core` with each while this lint stayed
# silent and the build stayed clean. `dlopen`/`dlsym` look a symbol up by name at
# runtime; `@_silgen_name` binds one at link time without a header; the CFBundle
# call is the Core Foundation spelling of `dlsym`.
PRIVATE_API = re.compile(
    r"\bdlsym\b|\bdlopen\b|\b_AX[A-Za-z]+"
    r"|@_silgen_name|\bCFBundleGetFunctionPointerForName\b"
)
PRIVATE_API_ALLOWED: set[str] = set()


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    problems = []

    for target, forbidden in FORBIDDEN_IMPORTS.items():
        directory = root / "Sources" / target
        if not directory.is_dir():
            problems.append(f"{target}: no such directory — has a target been renamed?")
            continue
        for path in sorted(directory.rglob("*.swift")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                match = re.match(r"\s*(?:@[a-zA-Z]+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                if match and match.group(1) in forbidden:
                    problems.append(
                        f"{path.relative_to(root)}:{number}: {target} must not import {match.group(1)}"
                    )

    for path in sorted((root / "Sources").rglob("*.swift")):
        target = path.relative_to(root / "Sources").parts[0]
        if target in PRIVATE_API_ALLOWED:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            found = PRIVATE_API.search(line)
            if found:
                problems.append(
                    f"{path.relative_to(root)}:{number}: {found.group(0)} is private API — "
                    "the tree deliberately has none left"
                )

    if problems:
        print("error: the target layering has been violated.\n")
        print("\n".join(problems))
        print("\nSee the comment at the top of this script for why each rule exists.")
        return 1

    print("layering lint: target dependencies and the private-API quarantine hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
