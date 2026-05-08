#!/usr/bin/env bash
# Auto-review Stop hook for /fusion.
# Reviews working tree changes via codex once per Claude response.
# All abnormal branches: silent exit 0 (hooks must not be noisy).

set -u

# 0. Pre-checks
command -v codex >/dev/null 2>&1 || exit 0
command -v git   >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

SKILL_DIR="$HOME/.claude/skills/fusion"
[[ -d "$SKILL_DIR" ]] || exit 0

# 1. Filter (a) — empty diff
DIFF_TEXT="$(git diff HEAD 2>/dev/null)"
[[ -z "$DIFF_TEXT" ]] && exit 0

# 2. Filter (b) — diff size threshold
DIFF_LINES=$(printf '%s\n' "$DIFF_TEXT" | wc -l)
DIFF_LINES=${DIFF_LINES##* }
if (( DIFF_LINES < 3 )); then
    exit 0
fi
if (( DIFF_LINES > 500 )); then
    printf '[fusion] 변경 %d줄 (>500). 자동 리뷰 skip — /fusion 수동 호출 권장.\n' "$DIFF_LINES"
    exit 0
fi

# Subsequent filter and codex steps will be added in later tasks.
exit 0
