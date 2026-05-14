#!/usr/bin/env bash
# Static checks that the package is documented as a Claude Code plugin package.

set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
README="$ROOT/README.md"
INSTALL="$ROOT/install.sh"
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

assert_contains "README names package type" "$README" "Claude Code plugin package"
assert_contains "README documents two-package layout" "$README" "## Two-package layout"
assert_contains "README distinguishes Codex role" "$README" "Codex is invoked only as the read-only reviewer"
assert_contains "README documents separate companion plugin" "$README" "Codex companion plugin is packaged separately under"
assert_contains "install output uses package name" "$INSTALL" "Claude Fusion plugin package"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
