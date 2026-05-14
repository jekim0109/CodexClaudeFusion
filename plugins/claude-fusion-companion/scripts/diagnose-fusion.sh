#!/usr/bin/env bash
# Read-only diagnostics for the Claude Fusion plugin package.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../../.. && pwd)"

print_link() {
    local label="$1"
    local path="$2"
    if [[ -L "$path" ]]; then
        printf '%s: symlink -> %s\n' "$label" "$(readlink "$path")"
    elif [[ -e "$path" ]]; then
        printf '%s: exists but is not a symlink\n' "$label"
    else
        printf '%s: missing\n' "$label"
    fi
}

printf 'Claude Fusion companion diagnostics\n'
printf 'repo: %s\n\n' "$ROOT"

print_link "claude skill fusion" "$HOME/.claude/skills/fusion"
print_link "claude skill fusion-debug" "$HOME/.claude/skills/fusion-debug"

printf '\ncommands:\n'
if command -v codex >/dev/null 2>&1; then
    printf 'codex: %s\n' "$(command -v codex)"
    codex --version 2>/dev/null || true
else
    printf 'codex: missing\n'
fi

if command -v claude >/dev/null 2>&1; then
    printf 'claude: %s\n' "$(command -v claude)"
    claude --version 2>/dev/null || true
else
    printf 'claude: missing\n'
fi

printf '\nproject opt-ins:\n'
if [[ -f "$PWD/.claude/settings.json" ]]; then
    printf 'project settings: %s\n' "$PWD/.claude/settings.json"
    if grep -q '"fusion"' "$PWD/.claude/settings.json"; then
        printf 'fusion settings: present\n'
    else
        printf 'fusion settings: absent\n'
    fi
    if grep -q 'auto-review-hook.sh' "$PWD/.claude/settings.json"; then
        printf 'auto review hook: present\n'
    else
        printf 'auto review hook: absent\n'
    fi
else
    printf 'project settings: missing\n'
fi

printf '\nnotes:\n'
printf '%s\n' '- /fusion and /fusion-debug run inside Claude Code, not this Codex companion.'
printf '%s\n' '- Sandboxed claude auth checks can falsely report logged out; verify outside the sandbox before re-login.'
