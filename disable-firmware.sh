#!/usr/bin/env bash
# Disable /fusion firmware mode for the current (or given) project.
# Removes fusion.firmware from <project>/.claude/settings.json.

set -euo pipefail

PROJECT="${1:-$PWD}"
SETTINGS="$PROJECT/.claude/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
    echo "Firmware mode not enabled (no $SETTINGS)."
    exit 0
fi

cp "$SETTINGS" "$SETTINGS.bak"

if ! python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
fusion = data.get("fusion", {})
removed = fusion.pop("firmware", None) is not None
if not fusion and "fusion" in data:
    del data["fusion"]
elif fusion:
    data["fusion"] = fusion
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"removed={removed}")
PYEOF
then
    echo "ERROR: settings.json 손상 — 백업 파일에서 복원하세요: cp \"$SETTINGS.bak\" \"$SETTINGS\"" >&2
    exit 1
fi

echo "Firmware mode disabled."
