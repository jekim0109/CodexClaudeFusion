#!/usr/bin/env bash
# Disable /fusion auto-review for the current (or given) project.
# Removes our Stop hook entry from <project>/.claude/settings.json.

set -euo pipefail

PROJECT="${1:-$PWD}"
HOOK_CMD='bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh'
SETTINGS="$PROJECT/.claude/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
    echo "Auto-review not enabled (no $SETTINGS)."
    exit 0
fi

cp "$SETTINGS" "$SETTINGS.bak"

if ! python3 - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
hooks = data.get("hooks", {})
stop = hooks.get("Stop", [])
removed = 0
new_stop = []
for entry in stop:
    inner = [h for h in entry.get("hooks", []) if h.get("command") != cmd]
    removed += len(entry.get("hooks", [])) - len(inner)
    if inner:
        new_entry = dict(entry)
        new_entry["hooks"] = inner
        new_stop.append(new_entry)
if new_stop:
    hooks["Stop"] = new_stop
elif "Stop" in hooks:
    del hooks["Stop"]
if not hooks and "hooks" in data:
    del data["hooks"]
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"removed {removed}")
PYEOF
then
    echo "ERROR: settings.json 손상 — 백업 파일에서 복원하세요: cp \"$SETTINGS.bak\" \"$SETTINGS\"" >&2
    exit 1
fi

echo "Auto-review disabled."
