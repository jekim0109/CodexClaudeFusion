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

# Resolve git's bin directory at host level (env -i strips PATH otherwise).
# This makes the test portable across Apple Silicon (/opt/homebrew/bin),
# Intel macOS (/usr/local/bin), and Linux (/usr/bin or wherever).
GIT_BIN_DIR="$(dirname "$(command -v git)")"

# stub_codex_dir: creates a tmp dir containing a fake `codex` and `git` (or only codex)
# usage: PATH="$(stub_codex_dir approved)":/usr/bin:/bin ...
stub_codex_dir() {
    # mode: "approved" | "revise" | "fail" | "missing"
    local mode="$1"
    local d
    d=$(mktemp -d)
    if [[ "$mode" != "missing" ]]; then
        cat > "$d/codex" <<STUB
#!/usr/bin/env bash
[[ -n "\${CODEX_CALLED_SENTINEL:-}" ]] && touch "\$CODEX_CALLED_SENTINEL"
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

run_hook_in() {
    # Args: <repo_dir> <stub_dir> <sentinel>
    local repo="$1" stub="$2" sent="$3"
    env -i HOME="$HOME" PATH="$stub:$GIT_BIN_DIR:/usr/bin:/bin" CODEX_CALLED_SENTINEL="$sent" \
        bash -c "cd '$repo' && bash '$HOOK'"
}

assert_called2() {
    local desc="$1" expected_exit="$2" expect_called="$3" expected_stdout_grep="$4"
    local repo="$5" stub="$6"
    local sentinel actual_out actual_exit was_called=no ok=1
    sentinel=$(mktemp -u); rm -f "$sentinel"
    actual_out="$(run_hook_in "$repo" "$stub" "$sentinel" 2>/dev/null)"
    actual_exit=$?
    [[ -e "$sentinel" ]] && was_called=yes
    rm -f "$sentinel"
    [[ "$actual_exit" == "$expected_exit" ]] || ok=0
    [[ "$was_called" == "$expect_called" ]] || ok=0
    [[ -z "$expected_stdout_grep" ]] || printf '%s' "$actual_out" | grep -qE "$expected_stdout_grep" || ok=0
    if (( ok )); then
        PASS=$((PASS+1)); printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1)); printf '  FAIL: %s\n    exp(exit=%s called=%s grep=%q) got(exit=%s called=%s out=%q)\n' \
            "$desc" "$expected_exit" "$expect_called" "$expected_stdout_grep" "$actual_exit" "$was_called" "$actual_out"
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
    env -i HOME="$HOME" PATH="$t_stub:$GIT_BIN_DIR:/usr/bin:/bin" bash -c "cd '$clean' && bash '$HOOK'"

# (5) tiny diff (2 changed lines → ~7 unified-diff lines) → silent
#     Note: the `<3` branch in the hook is essentially defensive — git diff
#     metadata adds ~5+ lines so any non-empty diff already exceeds the floor.
#     This case reaches trailing exit 0 via downstream filters (until task 5
#     wires codex). Kept for documentation and future-proofing if the hook
#     ever counts changed lines instead of unified-diff lines.
tiny=$(prep_repo_with_change 2)
assert_run "diff 2 lines → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:$GIT_BIN_DIR:/usr/bin:/bin" bash -c "cd '$tiny' && bash '$HOOK'"

# (6) huge diff (>500 lines) → warning + skip
huge=$(prep_repo_with_change 600)
assert_run "diff 600 lines → warning + skip" 0 ">500" \
    env -i HOME="$HOME" PATH="$t_stub:$GIT_BIN_DIR:/usr/bin:/bin" bash -c "cd '$huge' && bash '$HOOK'"

# (7) medium diff (10 lines) → reaches codex stub (which writes APPROVED) but
#     since later filters and codex aren't wired yet, behavior is "silent exit 0"
#     after this task. Reassert in later tasks.
mid=$(prep_repo_with_change 10)
assert_run "diff 10 lines → silent (post-task-2; codex not wired yet)" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:$GIT_BIN_DIR:/usr/bin:/bin" bash -c "cd '$mid' && bash '$HOOK'"

# --- pattern filter cases ---

prep_repo_with_files() {
    # Args: filename1 filename2 ...
    local d
    d=$(mktmprepo)
    for f in "$@"; do
        mkdir -p "$d/$(dirname "$f")" 2>/dev/null
        for ((i=1; i<=10; i++)); do printf 'line %d\n' "$i" >> "$d/$f"; done
    done
    git -C "$d" add . 2>/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base 2>/dev/null
    for f in "$@"; do
        printf 'extra1\nextra2\nextra3\nextra4\n' >> "$d/$f"
    done
    printf '%s' "$d"
}

# (8) only *.lock changed → all BLOCK → codex NOT called
lockonly=$(prep_repo_with_files yarn.lock)
assert_called2 "only yarn.lock changed → codex NOT called" 0 no "" "$lockonly" "$t_stub"

# (9) only *.md changed → all BLOCK → codex NOT called
mdonly=$(prep_repo_with_files docs/note.md)
assert_called2 "only *.md changed → codex NOT called" 0 no "" "$mdonly" "$t_stub"

# (10) Makefile + lock → Makefile is non-block → reaches stage past pattern filter
#      (codex still not wired in task 3, so expect_called=no for now; task 5 strengthens)
mkmix=$(prep_repo_with_files Makefile package-lock.json)
assert_called2 "Makefile + lock → reaches stage past pattern filter" 0 no "" "$mkmix" "$t_stub"

# (11) only *.c → non-block → reaches stage past pattern filter
conly=$(prep_repo_with_files src/foo.c)
assert_called2 "only *.c → reaches stage past pattern filter" 0 no "" "$conly" "$t_stub"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
