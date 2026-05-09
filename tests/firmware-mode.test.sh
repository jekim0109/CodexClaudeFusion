#!/usr/bin/env bash
# Test runner for firmware-mode prompt assembly branch in auto-review-hook.sh.
# Each case sets up a tmp git repo with controlled .claude/settings.json,
# runs the hook with stub codex, then inspects the assembled prompt file
# under /tmp/fusion-<ts>-<rand>/round-1-prompt.txt for the firmware section.

set -u
HOOK="$(cd "$(dirname "$0")"/.. && pwd)/skills/fusion/lib/auto-review-hook.sh"
GIT_BIN_DIR="$(dirname "$(command -v git)")"
PASS=0; FAIL=0

mktmprepo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    # add a non-block .c file change so the hook reaches prompt assembly
    printf 'int main(void){return 0;}\n' >> "$d/foo.c"
    git -C "$d" add foo.c
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
    printf 'extra1\nextra2\nextra3\nextra4\n' >> "$d/foo.c"
    printf '%s' "$d"
}

stub_codex_dir() {
    local d
    d=$(mktemp -d)
    cat > "$d/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
printf 'Overview: ok.\n\nNo actionable issues.\n\nVERDICT: APPROVED' > "$out"
exit 0
STUB
    chmod +x "$d/codex"
    printf '%s' "$d"
}

# Find the most recent /tmp/fusion-* directory created at or after a marker time.
latest_fusion_dir_since() {
    local marker="$1"
    local d
    for d in $(ls -td /tmp/fusion-* 2>/dev/null); do
        local ts="${d##*/fusion-}"
        ts="${ts%%-*}"
        if [[ "$ts" -ge "$marker" ]]; then
            printf '%s' "$d"
            return 0
        fi
    done
    printf ''
}

run_hook_and_get_prompt() {
    local repo="$1" stub="$2"
    local marker
    marker=$(date +%s)
    sleep 1
    env -i HOME="$HOME" PATH="$stub:$GIT_BIN_DIR:/usr/bin:/bin" \
        bash -c "cd '$repo' && bash '$HOOK'" >/dev/null 2>&1 || true
    local fdir
    fdir=$(latest_fusion_dir_since "$marker")
    [[ -n "$fdir" && -f "$fdir/round-1-prompt.txt" ]] && printf '%s/round-1-prompt.txt' "$fdir"
}

assert_prompt_contains() {
    local desc="$1" prompt_file="$2" needle="$3"
    if [[ -z "$prompt_file" ]]; then
        FAIL=$((FAIL+1)); printf '  FAIL: %s (no prompt file produced)\n' "$desc"
        return
    fi
    if grep -q "$needle" "$prompt_file"; then
        PASS=$((PASS+1)); printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1)); printf '  FAIL: %s (needle %q missing from %s)\n' "$desc" "$needle" "$prompt_file"
    fi
}

assert_prompt_not_contains() {
    local desc="$1" prompt_file="$2" needle="$3"
    if [[ -z "$prompt_file" ]]; then
        FAIL=$((FAIL+1)); printf '  FAIL: %s (no prompt file produced)\n' "$desc"
        return
    fi
    if grep -q "$needle" "$prompt_file"; then
        FAIL=$((FAIL+1)); printf '  FAIL: %s (needle %q present in %s but should not be)\n' "$desc" "$needle" "$prompt_file"
    else
        PASS=$((PASS+1)); printf '  PASS: %s\n' "$desc"
    fi
}

t_stub=$(stub_codex_dir)
NEEDLE='FIRMWARE-SPECIFIC REVIEW RULES'

# (1) firmware:true → prompt contains firmware section
r1=$(mktmprepo)
mkdir -p "$r1/.claude"
cat > "$r1/.claude/settings.json" <<'JSON'
{"fusion": {"firmware": true}}
JSON
p1=$(run_hook_and_get_prompt "$r1" "$t_stub")
assert_prompt_contains "firmware:true → firmware section in prompt" "$p1" "$NEEDLE"

# (2) firmware:false → prompt does NOT contain firmware section
r2=$(mktmprepo)
mkdir -p "$r2/.claude"
cat > "$r2/.claude/settings.json" <<'JSON'
{"fusion": {"firmware": false}}
JSON
p2=$(run_hook_and_get_prompt "$r2" "$t_stub")
assert_prompt_not_contains "firmware:false → no firmware section" "$p2" "$NEEDLE"

# (3) settings.json absent → prompt does NOT contain firmware section
r3=$(mktmprepo)
p3=$(run_hook_and_get_prompt "$r3" "$t_stub")
assert_prompt_not_contains "settings.json absent → no firmware section" "$p3" "$NEEDLE"

# (4) settings.json corrupt JSON → fallback to base, prompt does NOT contain firmware section
r4=$(mktmprepo)
mkdir -p "$r4/.claude"
printf '{ this is not json' > "$r4/.claude/settings.json"
p4=$(run_hook_and_get_prompt "$r4" "$t_stub")
assert_prompt_not_contains "settings.json corrupt → no firmware section (silent fallback)" "$p4" "$NEEDLE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
