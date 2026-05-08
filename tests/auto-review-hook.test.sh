#!/usr/bin/env bash
# Plain bash test runner for auto-review-hook.sh.
# Each case sets up an isolated tmp git repo, runs the hook with controlled PATH,
# and asserts the hook's stdout, stderr, and exit status.

set -u
HOOK="$(cd "$(dirname "$0")"/.. && pwd)/skills/fusion/lib/auto-review-hook.sh"
FAIL=0
PASS=0

mktmprepo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    printf '%s' "$d"
}

# stub_codex_dir: creates a tmp dir containing a fake `codex` and `git` (or only codex)
# usage: PATH="$(stub_codex_dir approved)":/usr/bin:/bin ...
stub_codex_dir() {
    local mode="$1"     # "approved" | "revise" | "fail" | "missing"
    local d
    d=$(mktemp -d)
    if [[ "$mode" != "missing" ]]; then
        cat > "$d/codex" <<STUB
#!/usr/bin/env bash
# Fake codex: parses -o <file>, writes a canned reviewer message there.
out=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$mode" in
    approved) printf 'Overview: ok.\n\nNo actionable issues.\n\nVERDICT: APPROVED' > "\$out" ;;
    revise)   printf 'Overview\n\n- BLOCKER: x.c:1 — bad — — fix\n\nVERDICT: REVISE'   > "\$out" ;;
    fail)     exit 7 ;;
esac
exit 0
STUB
        chmod +x "$d/codex"
    fi
    printf '%s' "$d"
}

assert_run() {
    local desc="$1" expected_exit="$2" expected_stdout_grep="$3"
    shift 3
    local actual_out actual_exit
    actual_out="$("$@" 2>/dev/null)"
    actual_exit=$?
    local ok=1
    [[ "$actual_exit" == "$expected_exit" ]] || ok=0
    if [[ -n "$expected_stdout_grep" ]]; then
        printf '%s' "$actual_out" | grep -qE "$expected_stdout_grep" || ok=0
    else
        [[ -z "$actual_out" ]] || ok=0
    fi
    if (( ok )); then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s\n    expected_exit=%s grep=%q\n    got_exit=%s out=%q\n' \
            "$desc" "$expected_exit" "$expected_stdout_grep" "$actual_exit" "$actual_out"
    fi
}

# --- pre-check cases (codex/git/skill-dir/git-tree) ---

t_repo=$(mktmprepo)
t_stub=$(stub_codex_dir approved)

# (1) codex missing → silent
assert_run "no codex on PATH → silent" 0 "" \
    env -i HOME="$HOME" PATH="/usr/bin:/bin" bash -c "cd '$t_repo' && bash '$HOOK'"

# (2) outside git tree → silent
non_git_dir=$(mktemp -d)
assert_run "outside git tree → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$non_git_dir' && bash '$HOOK'"

# (3) skill dir missing → silent (HOME has no .claude/skills/fusion)
empty_home=$(mktemp -d)
assert_run "skill dir missing → silent" 0 "" \
    env -i HOME="$empty_home" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$t_repo' && bash '$HOOK'"

# --- size-filter cases ---

# helper: prepare a tmp repo with N changed lines in foo.c
prep_repo_with_change() {
    local lines="$1"
    local d
    d=$(mktmprepo)
    : > "$d/foo.c"
    git -C "$d" add foo.c
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
    for ((i=1; i<=lines; i++)); do printf 'line %d\n' "$i" >> "$d/foo.c"; done
    printf '%s' "$d"
}

# (4) clean working tree → silent
clean=$(mktmprepo)
assert_run "clean working tree → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/opt/homebrew/bin:/usr/bin:/bin" bash -c "cd '$clean' && bash '$HOOK'"

# (5) tiny diff (2 lines) → silent
tiny=$(prep_repo_with_change 2)
assert_run "diff 2 lines → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/opt/homebrew/bin:/usr/bin:/bin" bash -c "cd '$tiny' && bash '$HOOK'"

# (6) huge diff (>500 lines) → warning + skip
huge=$(prep_repo_with_change 600)
assert_run "diff 600 lines → warning + skip" 0 ">500" \
    env -i HOME="$HOME" PATH="$t_stub:/opt/homebrew/bin:/usr/bin:/bin" bash -c "cd '$huge' && bash '$HOOK'"

# (7) medium diff (10 lines) → reaches codex stub (which writes APPROVED) but
#     since later filters and codex aren't wired yet, behavior is "silent exit 0"
#     after this task. Reassert in later tasks.
mid=$(prep_repo_with_change 10)
assert_run "diff 10 lines → silent (post-task-2; codex not wired yet)" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/opt/homebrew/bin:/usr/bin:/bin" bash -c "cd '$mid' && bash '$HOOK'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
