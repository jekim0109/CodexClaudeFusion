#!/usr/bin/env bash
# Static and smoke checks for the Codex companion plugin.

set -u
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
PLUGIN="$ROOT/plugins/claude-fusion-companion"
MANIFEST="$PLUGIN/.codex-plugin/plugin.json"
MARKETPLACE="$ROOT/.agents/plugins/marketplace.json"
SKILL="$PLUGIN/skills/fusion-status/SKILL.md"
REVIEW_SKILL="$PLUGIN/skills/fusion-claude-review/SKILL.md"
SCRIPT="$PLUGIN/scripts/diagnose-fusion.sh"
REVIEW_SCRIPT="$PLUGIN/scripts/claude-review-diff.sh"
FAIL=0
PASS=0

pass() {
    PASS=$((PASS+1))
    printf '  PASS: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL+1))
    printf '  FAIL: %s\n' "$1"
}

assert_file() {
    [[ -f "$2" ]] && pass "$1" || fail "$1"
}

assert_contains() {
    local desc="$1" file="$2" needle="$3"
    if grep -qF "$needle" "$file"; then
        pass "$desc"
    else
        fail "$desc"
        printf '    missing: %s\n' "$needle"
    fi
}

assert_file "plugin manifest exists" "$MANIFEST"
assert_file "marketplace exists" "$MARKETPLACE"
assert_file "fusion-status skill exists" "$SKILL"
assert_file "fusion-claude-review skill exists" "$REVIEW_SKILL"
assert_file "diagnostic script exists" "$SCRIPT"
assert_file "claude review script exists" "$REVIEW_SCRIPT"

python3 -m json.tool "$MANIFEST" >/dev/null 2>&1 && pass "manifest JSON parses" || fail "manifest JSON parses"
python3 -m json.tool "$MARKETPLACE" >/dev/null 2>&1 && pass "marketplace JSON parses" || fail "marketplace JSON parses"

assert_contains "manifest names plugin" "$MANIFEST" '"name": "claude-fusion-companion"'
assert_contains "manifest points to skills" "$MANIFEST" '"skills": "./skills/"'
assert_contains "marketplace points to plugin path" "$MARKETPLACE" '"path": "./plugins/claude-fusion-companion"'
assert_contains "skill states boundary" "$SKILL" "Claude Fusion is primarily a Claude Code plugin package."
assert_contains "skill forbids replacing runtime" "$SKILL" "does not run the Claude-side pingpong loop"
assert_contains "review skill states direction" "$REVIEW_SKILL" "Codex is the author and Claude is the read-only reviewer."
assert_contains "review script disables Claude tools" "$REVIEW_SCRIPT" 'claude --print --tools ""'

diagnostic_out="$(bash "$SCRIPT" 2>/dev/null)"
printf '%s' "$diagnostic_out" | grep -q "Claude Fusion companion diagnostics" && pass "diagnostic script runs" || fail "diagnostic script runs"
printf '%s' "$diagnostic_out" | grep -q "/fusion and /fusion-debug run inside Claude Code" && pass "diagnostic explains runtime boundary" || fail "diagnostic explains runtime boundary"

tmprepo="$(mktemp -d)"
git -C "$tmprepo" init -q
git -C "$tmprepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'old\n' > "$tmprepo/file.txt"
git -C "$tmprepo" add file.txt
git -C "$tmprepo" -c user.email=t@t -c user.name=t commit -q -m base
printf 'new\n' > "$tmprepo/file.txt"
prompt_file="$(mktemp)"
if (cd "$tmprepo" && bash "$REVIEW_SCRIPT" --dry-run --output "$prompt_file" "review context" >/dev/null); then
    pass "review script dry-run succeeds"
else
    fail "review script dry-run succeeds"
fi
grep -q "Codex is the author" "$prompt_file" && pass "review prompt states author" || fail "review prompt states author"
grep -q "VERDICT: APPROVED" "$prompt_file" && pass "review prompt includes verdict format" || fail "review prompt includes verdict format"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
