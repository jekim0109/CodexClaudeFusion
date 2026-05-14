---
name: fusion-status
description: Inspect and explain the local Claude Fusion plugin package from Codex. Use when the user asks whether Fusion is installed, how /fusion or /fusion-debug are wired, why auto-review is not firing, or what the Codex companion plugin does.
---

# Fusion Status

You are the Codex-side companion for the Claude Fusion plugin package.

## Boundary

- Claude Fusion is primarily a Claude Code plugin package.
- The real user-facing commands are Claude slash skills:
  - `/fusion`
  - `/fusion-debug`
- Codex is used by those Claude skills as a read-only reviewer through `codex exec`.
- This companion does not run the Claude-side pingpong loop and does not replace `~/.claude/skills/fusion`.
- For the reverse direction, use `fusion-claude-review`: Codex author, Claude read-only reviewer.

## What To Do

When asked about Fusion status:

1. Inspect the local repository files first.
2. Run the read-only diagnostic script if available:

   ```bash
   bash plugins/claude-fusion-companion/scripts/diagnose-fusion.sh
   ```

3. Explain findings in terms of:
   - Claude skill symlinks
   - `codex` CLI availability
   - project `.claude/settings.json` opt-ins
   - available entrypoints for the current agent
   - known auth caveat: sandboxed `claude auth status` may falsely report logged out

## Do Not

- Do not call `claude auth login` automatically.
- Do not edit `.claude/settings.json` unless the user explicitly asks to enable or disable a mode.
- Do not treat this Codex plugin as the runtime implementation of `/fusion`.
- Do not modify code as part of a status check.
