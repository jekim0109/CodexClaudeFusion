---
name: fusion-claude-review
description: Ask Claude to inspect the current Codex-authored working tree diff as a read-only reviewer. Use when Codex did the main implementation work and the user wants Claude inspection without changing files.
---

# Fusion Claude Review

Codex is the author and Claude is the read-only reviewer.

## Boundary

- This is the reverse direction of Claude `/fusion`.
- It runs from Codex, not Claude Code.
- It does not execute `/fusion`.
- It does not let Claude edit files; Claude receives a no-tools prompt and returns review text.

## What To Do

1. Inspect the working tree status.
2. Run:

   ```bash
   bash plugins/claude-fusion-companion/scripts/claude-review-diff.sh
   ```

3. Report Claude's findings to the user.
4. If Claude returns `VERDICT: REVISE`, Codex may implement fixes only after reviewing whether each finding is valid.

## Review Contract

Claude must review the current `git diff HEAD` as a read-only inspector and use:

- `BLOCKER`
- `MAJOR`
- `MINOR`
- final line `VERDICT: APPROVED` or `VERDICT: REVISE`

## Do Not

- Do not ask Claude to modify files.
- Do not treat Claude auth-status false negatives in sandboxed contexts as proof the user is logged out.
- Do not run destructive git commands.
- Do not apply Claude feedback blindly.
