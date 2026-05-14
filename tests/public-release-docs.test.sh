#!/usr/bin/env bash
# Static checks for public release documentation.

set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
README="$ROOT/README.md"
LICENSE="$ROOT/LICENSE"
FAIL=0
PASS=0

assert_contains() {
    local desc="$1" file="$2" needle="$3"
    if grep -qF "$needle" "$file"; then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s\n    missing: %s\n    file: %s\n' "$desc" "$needle" "$file"
    fi
}

assert_contains "README has public install section" "$README" "## Public install"
assert_contains "README has public GitHub URL" "$README" "https://github.com/jekim0109/CodexClaudeFusion.git"
assert_contains "README says Codex companion is manual" "$README" "Codex companion plugin is included, but it is not auto-registered globally."
assert_contains "README links MIT license" "$README" "MIT License"
assert_contains "LICENSE is MIT" "$LICENSE" "MIT License"
assert_contains "LICENSE has copyright holder" "$LICENSE" "Copyright (c) 2026 jekim"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
