#!/usr/bin/env python3
"""Enforces the target layering, which until now existed only in prose.

Every milestone's task brief has restated these rules and every review has
checked them by hand. That worked, but it is exactly the kind of invariant that
holds until the one time nobody looks -- and M5 weakened the graph by giving
`WindowKit` a dependency on `SpaceKit`, which is a deliberate exception that
makes the rest of the rules easier to erode by accident.

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
  Core       -- no Foundation, no Config, no SpaceKit. The routing logic. Keeping
                Foundation out is what keeps it honest about being pure decision
                logic over injected seams; concrete collaborators are assembled
                in App.
  SpaceKit   -- the ONLY target allowed to touch private API. The point is blast
                radius: a macOS release that changes a SkyLight symbol must have
                one directory to break, not several.

`App` is unconstrained: it is the executable, its job is to join things
together, and it is untestable by construction anyway.
"""

import pathlib
import re
import sys

FORBIDDEN_IMPORTS = {
    "Geometry": {"AppKit", "Foundation", "Carbon", "ApplicationServices", "Core",
                 "Config", "WindowKit", "Hotkeys", "SpaceKit"},
    "Config": {"AppKit", "Carbon", "Core", "Hotkeys", "SpaceKit", "WindowKit"},
    "Core": {"Foundation", "Config", "SpaceKit", "AppKit"},
    # Geometry included because `Hotkeys` declares NO dependencies in
    # Package.swift. The first version of this table omitted it, so the lint
    # permitted an import the build would have rejected -- encoding a rule from
    # prose instead of from Package.swift, which is exactly the mistake that makes
    # a lint worth less than the file it claims to guard.
    "Hotkeys": {"Core", "Config", "SpaceKit", "WindowKit", "Geometry"},
    "SpaceKit": {"Core", "Config", "Hotkeys", "WindowKit", "AppKit"},
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
                "Core", "Hotkeys", "SpaceKit", "WindowKit", "Annotation",
                "OverlayUI"},
    "Annotation": {"AppKit", "Carbon", "ApplicationServices", "Geometry", "Config",
                   "Core", "Hotkeys", "SpaceKit", "WindowKit", "Capture",
                   "OverlayUI"},
    # The one AppKit layer. It may import AppKit and the two targets it sits on;
    # nothing else (no Carbon, no the window-manager modules).
    "OverlayUI": {"Carbon", "ApplicationServices", "Geometry", "Config", "Core",
                  "Hotkeys", "SpaceKit", "WindowKit"},
}

# Private-API entry points. Confined to SpaceKit so that a macOS change has one
# place to break rather than several.
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
PRIVATE_API_ALLOWED = {"SpaceKit"}


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
                    f"{path.relative_to(root)}:{number}: {found.group(0)} outside SpaceKit — "
                    "private API is quarantined there on purpose"
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
