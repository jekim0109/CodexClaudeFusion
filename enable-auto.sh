#!/usr/bin/env bash
# Enable /fusion auto-review for the current (or given) project.
# - Adds Stop hook entry into <project>/.claude/settings.json (safe merge).
# - Adds .fusion-cache.txt to <project>/.gitignore.
# - Backs up settings.json to .bak before edit.

set -euo pipefail

PROJECT="${1:-$PWD}"
HOOK_CMD='bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh'
SETTINGS="$PROJECT/.claude/settings.json"
GITIGNORE="$PROJECT/.gitignore"

mkdir -p "$PROJECT/.claude"

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.bak"
else
    printf '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
hooks = data.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
# look for an existing entry that matches our command
already = False
for entry in stop:
    for h in entry.get("hooks", []):
        if h.get("command") == cmd:
            already = True
            break
    if already:
        break
if not already:
    stop.append({"hooks": [{"type": "command", "command": cmd}]})
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("noop" if already else "added")
PYEOF

# .gitignore: append .fusion-cache.txt if not present
if [[ -f "$GITIGNORE" ]]; then
    if ! grep -qx '.fusion-cache.txt' "$GITIGNORE"; then
        printf '\n.fusion-cache.txt\n' >> "$GITIGNORE"
    fi
else
    printf '.fusion-cache.txt\n' > "$GITIGNORE"
fi

echo "Auto-review enabled in $PROJECT. Use disable-auto.sh to turn off."
