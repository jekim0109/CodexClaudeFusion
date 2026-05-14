#!/usr/bin/env bash
# Test runner for install-codex-companion.sh marketplace merge behavior.

set -u
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
INSTALL="$REPO/install-codex-companion.sh"
PASS=0
FAIL=0

assert_json() {
    local desc="$1" file="$2" expr="$3"
    if python3 -c "import json,sys; d=json.load(open('$file')); sys.exit(0 if ($expr) else 1)" 2>/dev/null; then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s — %s\n' "$desc" "$expr"
    fi
}

home1="$(mktemp -d)"
bash "$INSTALL" --home "$home1" >/dev/null
market1="$home1/.agents/plugins/marketplace.json"
assert_json "creates marketplace" "$market1" "d.get('name') == 'codex-local'"
assert_json "adds companion plugin" "$market1" "any(p.get('name') == 'claude-fusion-companion' for p in d.get('plugins', []))"
assert_json "uses absolute local plugin path" "$market1" "next(p for p in d['plugins'] if p['name']=='claude-fusion-companion')['source']['path'].endswith('/plugins/claude-fusion-companion')"
assert_json "sets availability policy" "$market1" "next(p for p in d['plugins'] if p['name']=='claude-fusion-companion')['policy']['installation'] == 'AVAILABLE'"

bash "$INSTALL" --home "$home1" >/dev/null
assert_json "idempotent companion entry" "$market1" "sum(1 for p in d.get('plugins', []) if p.get('name') == 'claude-fusion-companion') == 1"

home2="$(mktemp -d)"
mkdir -p "$home2/.agents/plugins"
cat > "$home2/.agents/plugins/marketplace.json" <<'JSON'
{
  "name": "existing-marketplace",
  "interface": {
    "displayName": "Existing Marketplace"
  },
  "plugins": [
    {
      "name": "other-plugin",
      "source": {"source": "local", "path": "/tmp/other-plugin"},
      "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
      "category": "Productivity"
    }
  ]
}
JSON
bash "$INSTALL" --home "$home2" >/dev/null
market2="$home2/.agents/plugins/marketplace.json"
assert_json "preserves existing marketplace name" "$market2" "d.get('name') == 'existing-marketplace'"
assert_json "preserves existing plugin" "$market2" "any(p.get('name') == 'other-plugin' for p in d.get('plugins', []))"
assert_json "adds companion alongside existing plugin" "$market2" "any(p.get('name') == 'claude-fusion-companion' for p in d.get('plugins', []))"
[[ -f "$market2.bak" ]] && { PASS=$((PASS+1)); printf '  PASS: creates backup on merge\n'; } || { FAIL=$((FAIL+1)); printf '  FAIL: creates backup on merge\n'; }

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
