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
  Config     -- no Carbon, no AppKit, no Core. It holds Codable DTOs for
                hand-editable JSON. It must not gain the ability to construct
                the geometry types, because those use `precondition` and would
                trap on a hand-edited file -- which is the entire reason the DTOs
                exist as separate types.
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
    "Hotkeys": {"Core", "Config", "SpaceKit", "WindowKit"},
    "SpaceKit": {"Core", "Config", "Hotkeys", "WindowKit", "AppKit"},
    "WindowKit": {"Core", "Config", "Hotkeys"},
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
PRIVATE_API = re.compile(r"\bdlsym\b|\bdlopen\b|\b_AX[A-Za-z]+")
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
