#!/bin/bash
# Rejects test assertions that cannot fail on this toolchain.
#
# Swift Testing 0.99.0 (the SPM package, which is the only way to run tests on a
# machine with Command Line Tools and no Xcode — see Package.swift) expands
# `#expect` incorrectly for a Bool compared against a Bool with `==` or `!=`.
# Measured on this machine, all four of these PASS:
#
#     #expect(true == false)
#     #expect(false == true)
#     #expect(someTrueValue == false)
#     #expect(someTrueValue != true)
#
# while `#expect(x == 2)` on an Int fails correctly, and so does
# `#expect(Bool(false))`. So the defect is specific to Bool-vs-Bool comparison,
# which is exactly the shape a negative Bool assertion naturally takes.
#
# A test that cannot fail is worse than no test, because it is counted as
# coverage. This is not detectable by a test — a guard written in the broken
# shape would pass whether or not the bug is present — so it is a lint.
#
# Write `#expect(!x)` and `#expect(x)` instead.
set -uo pipefail

cd "$(dirname "$0")/.."

offenders=$(grep -rn --include='*.swift' -E '#expect\([^)]*(==|!=)[[:space:]]*(true|false)\b' Tests/ || true)
reversed=$(grep -rn --include='*.swift' -E '#expect\([[:space:]]*(true|false)[[:space:]]*(==|!=)' Tests/ || true)

found=""
[ -n "$offenders" ] && found="$offenders"
[ -n "$reversed" ] && found="$found
$reversed"
found=$(printf '%s\n' "$found" | grep -v '^$' || true)

if [ -n "$found" ]; then
    echo "error: these assertions compare a Bool with == or != inside #expect."
    echo "On this toolchain they PASS regardless of the value. Use #expect(x) or #expect(!x)."
    echo
    printf '%s\n' "$found"
    exit 1
fi

echo "test lint: no assertions of a shape that cannot fail."
