#!/usr/bin/env bash
# Ask Claude to review the current Codex-authored diff without tools.

set -euo pipefail

DRY_RUN=0
OUTPUT_FILE=""
CONTEXT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --output)
            OUTPUT_FILE="${2:-}"
            shift 2
            ;;
        *)
            CONTEXT+="$1 "
            shift
            ;;
    esac
done
CONTEXT="${CONTEXT%" "}"

command -v git >/dev/null 2>&1 || { echo "ERROR: git missing" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not inside a git repository" >&2; exit 1; }

DIFF_TEXT="$(git diff HEAD)"
if [[ -z "$DIFF_TEXT" ]]; then
    echo "No tracked working tree diff to review."
    exit 0
fi

UNTRACKED="$(git ls-files --others --exclude-standard)"
PROMPT_FILE="${OUTPUT_FILE:-/tmp/fusion-claude-review-$(date +%s)-$(printf '%04x' $((RANDOM))).txt}"

{
    printf '%s\n' 'You are Claude, acting as the read-only reviewer in a reverse Fusion review.'
    printf '%s\n' 'Codex is the author. You MUST NOT modify files or request tool access.'
    printf '\n'
    printf '%s\n' 'CONTEXT'
    printf '%s\n' "- User/context: ${CONTEXT:-"(none)"}"
    printf '%s\n' '- Review target: current git diff HEAD.'
    if [[ -n "$UNTRACKED" ]]; then
        printf '%s\n' '- Note: untracked files exist but are not included in git diff HEAD:'
        printf '%s\n' "$UNTRACKED"
    fi
    printf '\n'
    printf '%s\n' 'CURRENT DIFF'
    printf '%s\n' '```diff'
    printf '%s\n' "$DIFF_TEXT"
    printf '%s\n' '```'
    printf '\n'
    printf '%s\n' 'OUTPUT FORMAT'
    printf '%s\n' '1. Overview (1-3 lines).'
    printf '%s\n' '2. Issues by severity, using only labels that apply:'
    printf '%s\n' '   - BLOCKER: <file:line> — what — why — suggested fix'
    printf '%s\n' '   - MAJOR:   <file:line> — what — why — suggested fix'
    printf '%s\n' '   - MINOR:   <file:line> — what — why — suggested fix'
    printf '%s\n' '   If no issues at all, write: No actionable issues.'
    printf '%s\n' '3. Final line MUST be exactly one of:'
    printf '%s\n' '   VERDICT: APPROVED'
    printf '%s\n' '   VERDICT: REVISE'
    printf '\n'
    printf '%s\n' 'RULES'
    printf '%s\n' '- APPROVED only when no BLOCKER and no MAJOR remain.'
    printf '%s\n' '- Style preferences alone are not grounds for REVISE.'
    printf '%s\n' '- Reference real lines from the diff. Do not invent code.'
    printf '%s\n' '- Keep review focused on the current diff.'
    printf '%s\n' '- Do not check auth status; if this prompt reached you, perform the review.'
} > "$PROMPT_FILE"

if (( DRY_RUN )); then
    echo "prompt: $PROMPT_FILE"
    exit 0
fi

command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI missing" >&2; exit 1; }

# Disable tools so Claude reviews only; this companion is the Codex-side reverse direction.
claude --print --tools "" < "$PROMPT_FILE"
