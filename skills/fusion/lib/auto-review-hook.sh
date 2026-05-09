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

# 3. Filter (c) — file pattern blocklist
BLOCK_PATTERNS=(
    "*.md" "*.txt" "*.lock" "*.log" "*.bak"
    "package-lock.json" "yarn.lock" "Cargo.lock" "pnpm-lock.yaml"
)

is_blocked() {
    local f="$1"
    local base; base="$(basename "$f")"
    local p
    for p in "${BLOCK_PATTERNS[@]}"; do
        case "$f" in $p) return 0 ;; esac
        case "$base" in $p) return 0 ;; esac
    done
    return 1
}

CHANGED_FILES=$(git diff HEAD --name-only)
all_blocked=1
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! is_blocked "$f"; then
        all_blocked=0
        break
    fi
done <<< "$CHANGED_FILES"
(( all_blocked )) && exit 0

# 4. Filter (d) — diff hash cache (read; write happens after a successful codex round)
PROJECT_ROOT=$(git rev-parse --show-toplevel)
CACHE_FILE="$PROJECT_ROOT/.fusion-cache.txt"
DIFF_HASH=$(printf '%s' "$DIFF_TEXT" | shasum -a 256 | awk '{print $1}')
if [[ -f "$CACHE_FILE" ]] && grep -qx "$DIFF_HASH" "$CACHE_FILE"; then
    exit 0
fi

# 5. Codex call (single round, no PREV_HISTORY)
FUSION_TS=$(date +%s)
FUSION_RAND=$(printf '%04x' $((RANDOM)))
FUSION_DIR="/tmp/fusion-${FUSION_TS}-${FUSION_RAND}"
mkdir -p "$FUSION_DIR"

PREV_HISTORY="(none)"
TASK_TEXT="[auto-review] Stop hook 자동 리뷰. Working tree changes shown below."
PROMPT_FILE="$FUSION_DIR/round-1-prompt.txt"
LAST_MSG_FILE="$FUSION_DIR/round-1-codex.txt"

export TASK_TEXT PREV_HISTORY DIFF_TEXT
python3 - "$SKILL_DIR/prompts/reviewer.md" "$PROMPT_FILE" <<'PYEOF'
import sys, os
tmpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])
with open(out_path, "w") as f:
    f.write(s)
PYEOF

SECONDS=0
if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2> "$FUSION_DIR/round-1-codex.stderr"; then
    sleep 1
    if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2>> "$FUSION_DIR/round-1-codex.stderr"; then
        exit 0
    fi
fi
ELAPSED=$SECONDS

# 6. VERDICT parse
VERDICT=$(bash "$SKILL_DIR/lib/parse-verdict.sh" < "$LAST_MSG_FILE")

# 7. Cache write (only on a successful round)
echo "$DIFF_HASH" >> "$CACHE_FILE"
tail -n 100 "$CACHE_FILE" > "$CACHE_FILE.tmp" 2>/dev/null && mv "$CACHE_FILE.tmp" "$CACHE_FILE"

# 8. Output
case "$VERDICT" in
    APPROVED)
        echo "[fusion] ✓ auto-review APPROVED (${ELAPSED}s)"
        ;;
    REVISE)
        BLOCKERS=$(grep -cE '^[[:space:]]*- BLOCKER:' "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        MAJORS=$(grep -cE   '^[[:space:]]*- MAJOR:'   "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        MINORS=$(grep -cE   '^[[:space:]]*- MINOR:'   "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        echo "[fusion] ⚠ auto-review REVISE — ${BLOCKERS} BLOCKER, ${MAJORS} MAJOR, ${MINORS} MINOR (state: $FUSION_DIR)"
        ;;
    *)
        exit 0
        ;;
esac
exit 0
