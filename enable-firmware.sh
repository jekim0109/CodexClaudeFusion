#!/usr/bin/env bash
# Enable /fusion firmware mode for the current (or given) project.
# Sets fusion.firmware = true in <project>/.claude/settings.json.
# Backs up settings.json to .bak before edit.

set -euo pipefail

PROJECT="${1:-$PWD}"
SETTINGS="$PROJECT/.claude/settings.json"

mkdir -p "$PROJECT/.claude"

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.bak"
else
    printf '{}' > "$SETTINGS"
fi

if ! python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
fusion = data.setdefault("fusion", {})
already = fusion.get("firmware") is True
fusion["firmware"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("noop" if already else "added")
PYEOF
then
    echo "ERROR: settings.json 손상 — 백업 파일에서 복원하세요: cp \"$SETTINGS.bak\" \"$SETTINGS\"" >&2
    exit 1
fi

echo "Firmware mode enabled in $PROJECT. Rules: ISR/race + Volatile correctness."
