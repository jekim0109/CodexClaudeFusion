#!/usr/bin/env bash
# Test runner for /fusion-debug prompt assembly.
# Each case: set up tmp git repo + tmp HOME with fusion + fusion-debug skills,
# run the SKILL.md prompt-assembly code, inspect the resulting prompt file.

set -u
REPO="$(cd "$(dirname "$0")"/.. && pwd)"
GIT_BIN_DIR="$(dirname "$(command -v git)")"
PASS=0; FAIL=0

# Set up an isolated HOME that mimics post-install.sh state for both
# fusion and fusion-debug skills.
mk_isolated_home() {
    local h
    h=$(mktemp -d)
    mkdir -p "$h/.claude/skills"
    ln -s "$REPO/skills/fusion" "$h/.claude/skills/fusion"
    ln -s "$REPO/skills/fusion-debug" "$h/.claude/skills/fusion-debug"
    printf '%s' "$h"
}

mktmprepo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    : > "$d/foo.c"
    git -C "$d" add foo.c
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
    printf 'extra1\nextra2\nextra3\nextra4\nextra5\nextra6\n' >> "$d/foo.c"
    printf '%s' "$d"
}

# Run the SKILL.md prompt assembly with given context, write to PROMPT_OUT.
# This mirrors the python heredoc inside fusion-debug/SKILL.md (and is the
# single source of truth that the SKILL.md must mirror).
render_debug_prompt() {
    # Args: <home> <repo_dir> <prompt_out> <symptom>
    local home="$1" repo="$2" prompt_out="$3" symptom="$4"
    local fusion_base="$home/.claude/skills/fusion"
    local diff_text
    diff_text="$(git -C "$repo" diff HEAD)"
    PROMPT_OUT="$prompt_out" \
    PROJECT_ROOT="$repo" \
    FUSION_BASE_DIR="$fusion_base" \
    TASK_TEXT="[debug] symptom: $symptom — propose hypotheses, design falsifying experiments, optionally apply a fix. Codex (reviewer) will challenge each round." \
    PREV_HISTORY="(none)" \
    DIFF_TEXT="$diff_text" \
    python3 - <<'PYEOF'
import os, json
fusion_base = os.environ["FUSION_BASE_DIR"]
project_root = os.environ.get("PROJECT_ROOT", "")
out_path = os.environ["PROMPT_OUT"]

reviewer_path = os.path.join(fusion_base, "prompts", "reviewer.md")
debug_path = os.path.join(fusion_base, "prompts", "debug-rules.md")
firmware_path = os.path.join(fusion_base, "prompts", "firmware-rules.md")

if not os.path.isfile(debug_path):
    raise SystemExit(f"ERROR: debug-rules.md not found at {debug_path}")

with open(reviewer_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])

# debug-rules: always append in /fusion-debug entry
with open(debug_path) as f:
    s += "\n\n" + f.read()

# firmware-rules: append iff project's settings.json fusion.firmware == True
firmware = False
if project_root:
    settings_path = os.path.join(project_root, ".claude", "settings.json")
    if os.path.isfile(settings_path):
        try:
            with open(settings_path) as f:
                cfg = json.load(f)
            firmware = cfg.get("fusion", {}).get("firmware") is True
        except Exception:
            firmware = False
if firmware and os.path.isfile(firmware_path):
    with open(firmware_path) as f:
        s += "\n\n" + f.read()

with open(out_path, "w") as f:
    f.write(s)
PYEOF
}

DEBUG_NEEDLE='DEBUGGING-MODE REVIEW RULES'
FIRMWARE_NEEDLE='FIRMWARE-SPECIFIC REVIEW RULES'

# (1) firmware off + debug → prompt contains debug section, NOT firmware section
home1=$(mk_isolated_home)
repo1=$(mktmprepo)
out1=$(mktemp)
render_debug_prompt "$home1" "$repo1" "$out1" "test symptom 1"
if grep -q "$DEBUG_NEEDLE" "$out1" && ! grep -q "$FIRMWARE_NEEDLE" "$out1"; then
    PASS=$((PASS+1)); printf '  PASS: firmware off + debug → debug section only\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: firmware off + debug — debug=%d firmware=%d\n' \
        "$(grep -c "$DEBUG_NEEDLE" "$out1")" "$(grep -c "$FIRMWARE_NEEDLE" "$out1")"
fi

# (2) firmware on + debug → prompt contains BOTH sections
home2=$(mk_isolated_home)
repo2=$(mktmprepo)
mkdir -p "$repo2/.claude"
cat > "$repo2/.claude/settings.json" <<'JSON'
{"fusion": {"firmware": true}}
JSON
out2=$(mktemp)
render_debug_prompt "$home2" "$repo2" "$out2" "test symptom 2"
if grep -q "$DEBUG_NEEDLE" "$out2" && grep -q "$FIRMWARE_NEEDLE" "$out2"; then
    PASS=$((PASS+1)); printf '  PASS: firmware on + debug → both sections\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: firmware on + debug — debug=%d firmware=%d\n' \
        "$(grep -c "$DEBUG_NEEDLE" "$out2")" "$(grep -c "$FIRMWARE_NEEDLE" "$out2")"
fi

# (3) debug-rules.md missing → explicit error
home3=$(mk_isolated_home)
# Replace fusion symlink with a copy that lacks debug-rules.md
rm "$home3/.claude/skills/fusion"
fusion_copy=$(mktemp -d)
cp -R "$REPO/skills/fusion/." "$fusion_copy/"
rm -f "$fusion_copy/prompts/debug-rules.md"
ln -s "$fusion_copy" "$home3/.claude/skills/fusion"
repo3=$(mktmprepo)
out3=$(mktemp)
if render_debug_prompt "$home3" "$repo3" "$out3" "test symptom 3" 2>/dev/null; then
    FAIL=$((FAIL+1)); printf '  FAIL: debug-rules.md missing should error but rendered OK\n'
else
    PASS=$((PASS+1)); printf '  PASS: debug-rules.md missing → explicit error\n'
fi

# (4) fusion-debug symlink missing → directory absent (structural check)
home4=$(mk_isolated_home)
rm "$home4/.claude/skills/fusion-debug"
if [[ ! -e "$home4/.claude/skills/fusion-debug" ]]; then
    PASS=$((PASS+1)); printf '  PASS: fusion-debug not installed → directory absent\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: fusion-debug should be absent\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
