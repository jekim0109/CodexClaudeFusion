#!/usr/bin/env bash
# Register the Codex companion plugin in a user-local marketplace file.

set -euo pipefail

TARGET_HOME="$HOME"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --home)
            TARGET_HOME="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$TARGET_HOME" ]]; then
    echo "ERROR: --home requires a path" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$REPO_DIR/plugins/claude-fusion-companion"
MARKETPLACE="$TARGET_HOME/.agents/plugins/marketplace.json"

if [[ ! -f "$PLUGIN_DIR/.codex-plugin/plugin.json" ]]; then
    echo "ERROR: companion plugin manifest missing: $PLUGIN_DIR/.codex-plugin/plugin.json" >&2
    exit 1
fi

mkdir -p "$(dirname "$MARKETPLACE")"

export MARKETPLACE PLUGIN_DIR
python3 - <<'PYEOF'
import json
import os
from pathlib import Path

marketplace = Path(os.environ["MARKETPLACE"])
plugin_dir = str(Path(os.environ["PLUGIN_DIR"]).resolve())

entry = {
    "name": "claude-fusion-companion",
    "source": {
        "source": "local",
        "path": plugin_dir,
    },
    "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL",
    },
    "category": "Productivity",
}

if marketplace.exists():
    data = json.loads(marketplace.read_text())
    backup = marketplace.with_suffix(marketplace.suffix + ".bak")
    backup.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
else:
    data = {
        "name": "codex-local",
        "interface": {
            "displayName": "Codex Local",
        },
        "plugins": [],
    }

plugins = data.setdefault("plugins", [])
replaced = False
for idx, plugin in enumerate(plugins):
    if plugin.get("name") == entry["name"]:
        plugins[idx] = entry
        replaced = True
        break

if not replaced:
    plugins.append(entry)

marketplace.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PYEOF

echo "Codex companion registered: $MARKETPLACE"
echo "Plugin path: $PLUGIN_DIR"
