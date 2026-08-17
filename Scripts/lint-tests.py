#!/usr/bin/env python3
"""Rejects test assertions that cannot fail on this toolchain.

Swift Testing 0.99.0 -- the SPM package, which is the only way to run tests on a
machine with Command Line Tools and no Xcode, see Package.swift -- expands
`#expect` incorrectly when a Bool is compared to a Bool. Measured on this
machine, every one of these PASSES:

    #expect(true == false)
    #expect(someTrueValue == false)
    #expect(someTrueValue != true)
    #expect(f() == false)
    #expect(boolA == boolB)
    #expect(
        f() == false
    )

while `#expect(1 == 2)` fails correctly, and so does `#expect(Bool(false))`.

A test that cannot fail is worse than no test, because it is counted as
coverage. This project has produced such tests three times. It cannot be caught
by a test -- a guard written in the broken shape would pass whether or not the
bug is present -- so it is a lint.

The first version of this was a one-line grep for a `true`/`false` literal. A
reviewer defeated it three ways in about a minute: `f() == false` escaped the
character class, `boolA == boolB` has no literal at all, and wrapping the
assertion over two lines escaped a line-based tool entirely. So this version
extracts each `#expect(...)` as a full balanced expression across however many
lines it spans, and then checks it.

WHAT THIS CANNOT CATCH: `#expect(boolA == boolB)`, where neither side is a
literal. Detecting it needs type information, which a lint does not have. The
rule for contributors is therefore simpler than the lint: **never use `==` or
`!=` on Bools inside `#expect`.** Write `#expect(x)` and `#expect(!x)`.
"""

import pathlib
import re
import sys

BAD = re.compile(r"(==|!=)\s*(true|false)\b|\b(true|false)\s*(==|!=)")


def expectations(source: str):
    """Yields (line number, full expression) for every `#expect(` in `source`.

    Tracks parenthesis depth so an assertion spanning several lines is examined
    as one expression rather than as unrelated fragments.
    """
    for match in re.finditer(r"#expect\(", source):
        start = match.end()
        depth = 1
        index = start
        while index < len(source) and depth:
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
            index += 1
        yield source.count("\n", 0, match.start()) + 1, source[start : index - 1]


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    problems = []
    for path in sorted((root / "Tests").rglob("*.swift")):
        source = path.read_text()
        for line, expression in expectations(source):
            if BAD.search(expression):
                flat = " ".join(expression.split())
                problems.append(
                    f"{path.relative_to(root)}:{line}: #expect({flat})"
                )

    if problems:
        print(
            "error: these assertions compare a Bool with == or != inside #expect.\n"
            "On this toolchain they PASS regardless of the value.\n"
            "Write #expect(x) or #expect(!x).\n"
        )
        print("\n".join(problems))
        return 1

    print("test lint: no assertions of a shape that cannot fail.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
