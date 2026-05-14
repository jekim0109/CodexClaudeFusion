#!/usr/bin/env bash
# Static checks for reviewer prompt safety rules.

set -u
PROMPT="$(cd "$(dirname "$0")"/.. && pwd)/skills/fusion/prompts/reviewer.md"
FAIL=0
PASS=0

assert_contains() {
    local desc="$1" needle="$2"
    if grep -qF "$needle" "$PROMPT"; then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s\n    missing: %s\n' "$desc" "$needle"
    fi
}

assert_contains "reviewer ignores Claude auth status" "Do not check Claude authentication state"
assert_contains "reviewer uses supplied diff as source of truth" "The supplied task, previous rounds, and CURRENT DIFF are the source of truth"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
