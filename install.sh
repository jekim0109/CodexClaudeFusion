#!/usr/bin/env bash
# Install /fusion and /fusion-debug skills by symlinking
# ~/.claude/skills/fusion (review pingpong) and ~/.claude/skills/fusion-debug
# (systematic-debugging pingpong) to this repo.
# Idempotent: noop if links are already correct; refuses to overwrite a non-symlink.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_PARENT="$HOME/.claude/skills"
mkdir -p "$DEST_PARENT"

# Idempotent symlink installer for one skill name.
install_skill() {
    local name="$1"
    local src="$REPO_DIR/skills/$name"
    local dest="$DEST_PARENT/$name"

    if [[ ! -d "$src" ]]; then
        echo "ERROR: source not found: $src" >&2
        exit 1
    fi

    if [[ -L "$dest" ]]; then
        local current
        current="$(readlink "$dest")"
        if [[ "$current" == "$src" ]]; then
            echo "OK: $dest already points to $src (no change)"
            return 0
        fi
        echo "REPLACING symlink: $dest"
        echo "  was -> $current"
        echo "  now -> $src"
        rm "$dest"
    elif [[ -e "$dest" ]]; then
        echo "ERROR: $dest exists but is not a symlink. Refusing to overwrite." >&2
        echo "       Move or remove it manually, then re-run." >&2
        exit 1
    fi

    ln -s "$src" "$dest"
    echo "INSTALLED: $dest -> $src"
}

install_skill "fusion"
install_skill "fusion-debug"
echo "Claude Fusion plugin package installed."
echo "이제 Claude Code에서 /fusion (review) 와 /fusion-debug (systematic-debugging) 모두 사용 가능합니다."
