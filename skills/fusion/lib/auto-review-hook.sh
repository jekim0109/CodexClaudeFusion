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

# Subsequent filter and codex steps will be added in later tasks.
exit 0
