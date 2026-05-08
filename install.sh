#!/usr/bin/env bash
# Install /fusion skill by symlinking ~/.claude/skills/fusion to this repo's skills/fusion.
# Idempotent: noop if link is already correct; refuses to overwrite a non-symlink.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/skills/fusion"
DEST_PARENT="$HOME/.claude/skills"
DEST="$DEST_PARENT/fusion"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: source not found: $SRC" >&2
    exit 1
fi

mkdir -p "$DEST_PARENT"

if [[ -L "$DEST" ]]; then
    current="$(readlink "$DEST")"
    if [[ "$current" == "$SRC" ]]; then
        echo "OK: $DEST already points to $SRC (no change)"
        exit 0
    fi
    echo "REPLACING symlink: $DEST"
    echo "  was -> $current"
    echo "  now -> $SRC"
    rm "$DEST"
elif [[ -e "$DEST" ]]; then
    echo "ERROR: $DEST exists but is not a symlink. Refusing to overwrite." >&2
    echo "       Move or remove it manually, then re-run." >&2
    exit 1
fi

ln -s "$SRC" "$DEST"
echo "INSTALLED: $DEST -> $SRC"
echo "이제 Claude Code에서 /fusion 사용 가능합니다."
