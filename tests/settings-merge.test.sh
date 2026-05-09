#!/usr/bin/env bash
# Test runner for enable-auto.sh / disable-auto.sh JSON merge correctness.
set -u
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
ENABLE="$REPO/enable-auto.sh"
DISABLE="$REPO/disable-auto.sh"
PASS=0; FAIL=0

assert_json_contains() {
    local desc="$1" file="$2" pyexpr="$3"
    if python3 -c "import json,sys;d=json.load(open('$file'));sys.exit(0 if ($pyexpr) else 1)" 2>/dev/null; then
        PASS=$((PASS+1)); printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1)); printf '  FAIL: %s — %s\n' "$desc" "$pyexpr"
    fi
}

# Setup tmp project
proj=$(mktemp -d)
cd "$proj"
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# (1) enable on empty project: settings.json gets created with our hook
bash "$ENABLE" >/dev/null
assert_json_contains "settings.json created with hooks.Stop entry" \
    ".claude/settings.json" \
    "any('auto-review-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]))"

# (2) re-enable: idempotent (no duplicate)
bash "$ENABLE" >/dev/null
assert_json_contains "re-enable does not duplicate entry" \
    ".claude/settings.json" \
    "sum(1 for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]) if 'auto-review-hook.sh' in h.get('command','')) == 1"

# (3) preserve user's other hook entries
cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "bash /tmp/user-hook.sh"}]}
    ]
  }
}
JSON
bash "$ENABLE" >/dev/null
assert_json_contains "user's existing hook preserved alongside ours" \
    ".claude/settings.json" \
    "any('user-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[])) and any('auto-review-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]))"

# (4) .gitignore gets .fusion-cache.txt line
[[ -f .gitignore ]] && grep -qx '.fusion-cache.txt' .gitignore && \
    { PASS=$((PASS+1)); printf '  PASS: .gitignore contains .fusion-cache.txt\n'; } || \
    { FAIL=$((FAIL+1)); printf '  FAIL: .gitignore missing .fusion-cache.txt\n'; }

# (5) re-enable does not duplicate .gitignore line
bash "$ENABLE" >/dev/null
gi_count=$(grep -cx '.fusion-cache.txt' .gitignore 2>/dev/null || echo 0)
if [[ "$gi_count" == "1" ]]; then
    PASS=$((PASS+1)); printf '  PASS: .gitignore line not duplicated on re-enable\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: .gitignore line count = %s\n' "$gi_count"
fi

# (6) bak file is created on overwrite
[[ -f .claude/settings.json.bak ]] && \
    { PASS=$((PASS+1)); printf '  PASS: .bak created\n'; } || \
    { FAIL=$((FAIL+1)); printf '  FAIL: .bak missing\n'; }

# (7) disable removes our entry, preserves user's
bash "$DISABLE" >/dev/null
assert_json_contains "disable removes our entry, preserves user's" \
    ".claude/settings.json" \
    "(not any('auto-review-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]))) and any('user-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]))"

# (8) disable on already-disabled: noop
bash "$DISABLE" >/dev/null
assert_json_contains "disable when entry already absent: noop" \
    ".claude/settings.json" \
    "not any('auto-review-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]))"

# (9) disable with no settings.json at all: graceful
proj2=$(mktemp -d)
cd "$proj2"
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
out=$(bash "$DISABLE" 2>&1) && rc=0 || rc=$?
if [[ "$rc" == "0" ]]; then
    PASS=$((PASS+1)); printf '  PASS: disable on missing settings.json exits 0\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: disable missing settings.json rc=%s out=%q\n' "$rc" "$out"
fi
cd "$proj"

# --- Phase 3: enable-firmware.sh cases ---

ENABLE_FW="$REPO/enable-firmware.sh"
DISABLE_FW="$REPO/disable-firmware.sh"

# Setup fresh tmp project for firmware tests
proj_fw=$(mktemp -d)
cd "$proj_fw"
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# (10) enable-firmware on empty project: settings.json gets fusion.firmware=true
bash "$ENABLE_FW" >/dev/null
assert_json_contains "enable-firmware: fusion.firmware=true added" \
    ".claude/settings.json" \
    "d.get('fusion',{}).get('firmware') is True"

# (11) re-enable: idempotent
bash "$ENABLE_FW" >/dev/null
assert_json_contains "enable-firmware: idempotent (still true, no extra)" \
    ".claude/settings.json" \
    "d.get('fusion',{}).get('firmware') is True"

# (12) preserve existing hooks key alongside fusion key
cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "bash /tmp/user-hook.sh"}]}]
  }
}
JSON
bash "$ENABLE_FW" >/dev/null
assert_json_contains "enable-firmware: existing hooks preserved alongside fusion key" \
    ".claude/settings.json" \
    "any('user-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[])) and d.get('fusion',{}).get('firmware') is True"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
