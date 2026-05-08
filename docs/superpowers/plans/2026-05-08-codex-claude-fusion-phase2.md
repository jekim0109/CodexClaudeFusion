# Codex–Claude Fusion (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop hook으로 응답 끝마다 Codex 자동 리뷰 1라운드를 수행하는 `auto-review-hook.sh`와 project-local opt-in/out 스크립트를 빌드한다.

**Architecture:** 단일 bash hook + python heredoc (Phase 1 패턴). 4종 노이즈 필터(변경 없음/임계치/blocklist/해시 캐시) 통과 시에만 Codex 호출. 모든 비정상 분기는 silent exit 0. opt-in은 `.claude/settings.json`에 hook entry 안전 병합.

**Tech Stack:** bash, python3, `codex` CLI ≥ 0.128.0, `git`, `shasum`. 외부 의존 없음(Phase 1과 동일).

**Spec:** `docs/superpowers/specs/2026-05-08-codex-claude-fusion-phase2-design.md` (커밋 7b35362)

---

## File Structure

```
skills/fusion/
└── lib/
    ├── parse-verdict.sh         # Phase 1 (재사용, 변경 없음)
    └── auto-review-hook.sh      # Phase 2 신규: Stop hook 진입점
prompts/
└── reviewer.md                  # Phase 1 (재사용, 변경 없음)
enable-auto.sh                   # Phase 2 신규
disable-auto.sh                  # Phase 2 신규
tests/
├── parse-verdict.test.sh        # Phase 1 (재사용)
├── auto-review-hook.test.sh     # Phase 2 신규
└── settings-merge.test.sh       # Phase 2 신규: enable/disable 병합 검증
README.md                        # 변경: "자동 리뷰" 섹션 추가
```

각 파일 책임:
- `auto-review-hook.sh` — Stop hook이 호출. 사전 점검 → 4 필터 → Codex 호출 → VERDICT 파싱 → 한 줄 출력
- `enable-auto.sh` — `.claude/settings.json`에 hook entry 안전 병합 + `.gitignore`에 `.fusion-cache.txt` 추가
- `disable-auto.sh` — `.claude/settings.json`에서 fusion entry 정확 제거
- `auto-review-hook.test.sh` — hook 본체 단위 동작(필터·캐시) 검증. codex 호출 자체는 stub
- `settings-merge.test.sh` — enable/disable의 JSON 병합·제거 동작 검증

테스트 전략: codex CLI 호출은 mock 어려우므로, **PATH 앞쪽에 stub codex 스크립트**를 두는 방식 사용. stub은 미리 준비한 텍스트를 stdout/`-o` 파일에 출력하고 exit 0.

---

### Task 1: hook 골격 + 사전 점검 (TDD)

**Files:**
- Create: `skills/fusion/lib/auto-review-hook.sh`
- Create: `tests/auto-review-hook.test.sh`

사전 점검 4종(`codex` CLI, `git` CLI, git 트리 안, `~/.claude/skills/fusion` 존재) 중 하나라도 실패하면 silent exit 0.

- [ ] **Step 1: 테스트 작성**

`tests/auto-review-hook.test.sh` 파일 전체 내용:

```bash
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

권한:
```bash
chmod +x tests/auto-review-hook.test.sh
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 모든 케이스 FAIL (hook 파일 자체가 없음). 출력에 `0 passed, 3 failed`. exit 1.

- [ ] **Step 3: hook 골격 구현**

`skills/fusion/lib/auto-review-hook.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Auto-review Stop hook for /fusion.
# Reviews working tree changes via codex once per Claude response.
# All abnormal branches: silent exit 0 (hooks must not be noisy).

set -u

# 0. Pre-checks
command -v codex >/dev/null 2>&1 || exit 0
command -v git   >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

SKILL_DIR="$HOME/.claude/skills/fusion"
[[ -d "$SKILL_DIR" ]] || exit 0

# Subsequent filter and codex steps will be added in later tasks.
exit 0
```

권한:
```bash
chmod +x skills/fusion/lib/auto-review-hook.sh
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: `3 passed, 0 failed`. exit 0.

- [ ] **Step 5: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add skills/fusion/lib/auto-review-hook.sh tests/auto-review-hook.test.sh
git commit -m "feat: auto-review-hook 골격 + 사전 점검 테스트

Stop hook 진입점 골격. codex/git CLI 부재, git 외부, /fusion 스킬
미설치 케이스에서 silent exit 0. 임시 git 레포·stub codex로 3개
케이스 검증."
```

---

### Task 2: 변경 없음 + 변경량 임계치 필터 (TDD)

**Files:**
- Modify: `skills/fusion/lib/auto-review-hook.sh` (필터 a, b 추가)
- Modify: `tests/auto-review-hook.test.sh` (4 케이스 추가)

- [ ] **Step 1: 실패 테스트 추가**

`tests/auto-review-hook.test.sh`의 마지막 `printf '\n%s passed...` 라인 직전에 다음을 삽입:

```bash
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
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$clean' && bash '$HOOK'"

# (5) tiny diff (2 lines) → silent
tiny=$(prep_repo_with_change 2)
assert_run "diff 2 lines → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$tiny' && bash '$HOOK'"

# (6) huge diff (>500 lines) → warning + skip
huge=$(prep_repo_with_change 600)
assert_run "diff 600 lines → warning + skip" 0 ">500" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$huge' && bash '$HOOK'"

# (7) medium diff (10 lines) → reaches codex stub (which writes APPROVED) but
#     since later filters and codex aren't wired yet, behavior is "silent exit 0"
#     after this task. Reassert in later tasks.
mid=$(prep_repo_with_change 10)
assert_run "diff 10 lines → silent (post-task-2; codex not wired yet)" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$mid' && bash '$HOOK'"
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 4개 새 케이스 중 (6) `huge`이 "expected stdout grep `>500`" 매칭 못 해서 FAIL. 나머지 3개는 의도적 silent라 PASS. 합계: `6 passed, 1 failed`. exit 1.

- [ ] **Step 3: 필터 구현**

`skills/fusion/lib/auto-review-hook.sh`의 `# Subsequent filter and codex steps will be added in later tasks.\nexit 0` 두 줄을 다음으로 교체:

```bash
# 1. Filter (a) — empty diff
DIFF_TEXT="$(git diff HEAD 2>/dev/null)"
[[ -z "$DIFF_TEXT" ]] && exit 0

# 2. Filter (b) — diff size threshold
DIFF_LINES=$(printf '%s\n' "$DIFF_TEXT" | wc -l)
DIFF_LINES=${DIFF_LINES##* }
if (( DIFF_LINES < 3 )); then
    exit 0
fi
if (( DIFF_LINES > 500 )); then
    echo "[fusion] 변경 ${DIFF_LINES}줄 (>500). 자동 리뷰 skip — /fusion 수동 호출 권장."
    exit 0
fi

# Subsequent filter and codex steps will be added in later tasks.
exit 0
```

(`${DIFF_LINES##* }` 는 `wc -l`의 leading whitespace 제거 — macOS에서 `wc -l`이 공백 패딩 추가하는 경우가 있음.)

- [ ] **Step 4: 통과 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: `7 passed, 0 failed`. exit 0.

- [ ] **Step 5: 커밋**

```bash
git add skills/fusion/lib/auto-review-hook.sh tests/auto-review-hook.test.sh
git commit -m "feat: 변경 없음·변경량 임계치 필터 추가

git diff HEAD 비어있으면 silent skip. <3줄 silent skip,
>500줄 한 줄 경고 후 skip. macOS wc -l leading 공백 처리."
```

---

### Task 3: 파일 패턴 blocklist 필터 (TDD)

**Files:**
- Modify: `skills/fusion/lib/auto-review-hook.sh`
- Modify: `tests/auto-review-hook.test.sh`

스펙 §6 §3의 BLOCK list만 적용. 변경 파일 중 BLOCK 매칭이 아닌 파일이 1개 이상이면 진행, 모두 BLOCK이면 silent skip.

- [ ] **Step 1: 실패 테스트 추가**

`tests/auto-review-hook.test.sh` 파일 끝 `printf '\n%s passed...` 직전에 다음 추가:

```bash
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

# (8) only *.lock changed → silent (all BLOCK)
lockonly=$(prep_repo_with_files yarn.lock)
assert_run "only yarn.lock changed → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$lockonly' && bash '$HOOK'"

# (9) only *.md changed → silent
mdonly=$(prep_repo_with_files docs/note.md)
assert_run "only *.md changed → silent" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$mdonly' && bash '$HOOK'"

# (10) Makefile + package-lock.json → Makefile is non-block, proceeds (silent for now;
#      codex not wired yet, so exits silent at end of pipeline)
mkmix=$(prep_repo_with_files Makefile package-lock.json)
assert_run "Makefile + lock → proceeds (silent post-task-3)" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$mkmix' && bash '$HOOK'"

# (11) only *.c → proceeds (silent post-task-3)
conly=$(prep_repo_with_files src/foo.c)
assert_run "only *.c changed → proceeds (silent post-task-3)" 0 "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" bash -c "cd '$conly' && bash '$HOOK'"
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 임계치만 있는 hook은 `*.lock`도 그대로 진입 직전까지 가지만 codex 미연결이라 silent exit 0 → (8)(9)는 "PASS" 처럼 보일 수 있음. 그러나 정확하게는 (8)(9) 케이스에서 hook이 "BLOCK 필터로 skip"하는지 확인이 필요. 현재 hook은 BLOCK 필터 없으므로 변경량 통과 후 silent exit. 따라서 통과 grep "" + exit 0 둘 다 만족 → 모두 PASS로 보일 수 있음.

이 task의 핵심: 패턴 필터 추가가 *기능적으로* 동작하는지 검증. 위 (8)~(11) 그대로는 실패 확인이 어려우므로, hook 내부에 임시 디버그 echo (예: "stage: pattern OK")를 두고 grep으로 확인. 단, 그건 production 코드에 흔적이 남으니 깔끔하지 않음.

대안: stub codex가 호출됐는지 확인하는 sentinel 파일 사용:

위 `stub_codex_dir`에 sentinel 작성 추가:
```bash
# inside fake codex:
touch "${CODEX_CALLED_SENTINEL:-/dev/null}"
```

그리고 테스트는 `CODEX_CALLED_SENTINEL=$(mktemp)` 환경변수 설정 후 hook 실행, 끝나고 sentinel 존재 여부 확인.

이 변경을 함께 적용하세요. `stub_codex_dir`의 cat heredoc 안에 sentinel touch 추가하고, 새로운 helper `assert_called` / `assert_not_called`를 추가하세요. 다음 코드 블록을 testfile 상단의 `stub_codex_dir`을 교체하는 형태로 적용:

```bash
stub_codex_dir() {
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

# Args: <description> <expected_exit> <expected_called: yes|no> <expected_stdout_grep>
# Trailing args after the 4 fixed: command to run.
assert_called() {
    local desc="$1" expected_exit="$2" expect_called="$3" expected_stdout_grep="$4"
    shift 4
    local sentinel actual_out actual_exit
    sentinel=$(mktemp -u)
    rm -f "$sentinel"
    actual_out="$(CODEX_CALLED_SENTINEL="$sentinel" "$@" 2>/dev/null)"
    actual_exit=$?
    local was_called=no
    [[ -e "$sentinel" ]] && was_called=yes
    rm -f "$sentinel"
    local ok=1
    [[ "$actual_exit" == "$expected_exit" ]] || ok=0
    [[ "$was_called" == "$expect_called" ]] || ok=0
    if [[ -n "$expected_stdout_grep" ]]; then
        printf '%s' "$actual_out" | grep -qE "$expected_stdout_grep" || ok=0
    fi
    if (( ok )); then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s\n    expected_exit=%s expect_called=%s grep=%q\n    got_exit=%s called=%s out=%q\n' \
            "$desc" "$expected_exit" "$expect_called" "$expected_stdout_grep" \
            "$actual_exit" "$was_called" "$actual_out"
    fi
}
```

그리고 위에 작성한 (8)~(11) 케이스를 다음으로 교체 (assert_called 사용):

```bash
# (8) only *.lock changed → not called (all BLOCK)
lockonly=$(prep_repo_with_files yarn.lock)
assert_called "only yarn.lock changed → codex NOT called" 0 no "" \
    env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" \
        CODEX_CALLED_SENTINEL="$CODEX_CALLED_SENTINEL" \
        bash -c "cd '$lockonly' && bash '$HOOK'"
# Above doesn't actually pass the env var to env -i. Use this fixed form instead:

run_hook_in() {
    # Args: <repo_dir> <stub_dir> <sentinel>
    local repo="$1" stub="$2" sent="$3"
    env -i HOME="$HOME" PATH="$stub:/usr/bin:/bin" CODEX_CALLED_SENTINEL="$sent" \
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

assert_called2 "only yarn.lock changed → codex NOT called" 0 no "" "$lockonly" "$t_stub"
assert_called2 "only *.md changed → codex NOT called" 0 no "" "$mdonly" "$t_stub"
assert_called2 "Makefile + lock → codex CALLED (Makefile is non-block)" 0 yes "" "$mkmix" "$t_stub"
assert_called2 "only *.c → codex CALLED" 0 yes "" "$conly" "$t_stub"
```

(이전 (8)~(11) `assert_run` 호출 4줄은 모두 위 `assert_called2` 4줄로 교체. `assert_run`은 그 외 케이스에서 그대로 사용.)

- [ ] **Step 2: 실패 확인 (재차)**

Run: `bash tests/auto-review-hook.test.sh`
Expected: hook이 패턴 필터 없으므로 (10)(11)은 codex 호출 못 함 (codex 호출 자체는 Task 5에서). 하지만 (8)(9)는 BLOCK 필터로 skip 해야 하는데 현재는 그 단계까지 못 와서 `expect_called=no`이지만 또한 silent 진행 후 종료라 sentinel 파일도 없음 → 우연히 (8)(9) PASS. (10)(11)도 silent exit이고 codex 미호출이라 `expect_called=yes` 매칭 못해서 FAIL. 합계 FAIL ≥ 2.

이 케이스에 대한 의도적 정직: BLOCK 필터를 넣어야 (8)(9)가 의미 있는 검증이 됨. 그러나 codex가 task 5에 가야 호출되므로 (10)(11)은 task 3에서는 통과 못 함. 따라서 task 3에서는 (10)(11)을 임시로 다음과 같이 약하게:

```bash
assert_called2 "Makefile + lock → reaches stage past pattern filter" 0 no "" "$mkmix" "$t_stub"
assert_called2 "only *.c → reaches stage past pattern filter" 0 no "" "$conly" "$t_stub"
```

(`expect_called=no`로 두고 task 5에서 다시 `yes`로 강화.) 이렇게 적으세요.

이 약화로 다시 test 돌리면: task 3 진입 전 (8)(9) 우연히 PASS, (10)(11) 약화로 PASS. 합계 PASS만. 그러면 task 3 fix가 의미 있는지 확인 어려움.

실용적 절충: task 3 step 2의 expected는 "(8)(9)가 pattern 필터로 *명시적으로* skip 됨"을 직접 확인하기 어려우므로, **patten 필터 구현 후 sentinel 검증으로 skip 보장 + (10)(11)은 task 5에서 강화**.

- [ ] **Step 3: BLOCK 필터 구현**

`skills/fusion/lib/auto-review-hook.sh`의 `if (( DIFF_LINES > 500 )); then ... fi` 블록과 `# Subsequent filter and codex steps...` 사이에 다음 코드 삽입 (즉 임계치 필터 직후, exit 0 직전):

```bash

# 3. Filter (c) — file pattern blocklist
BLOCK_PATTERNS=(
    "*.md" "*.txt" "*.json" "*.lock" "*.log" "*.bak"
    "package-lock.json" "yarn.lock" "Cargo.lock" "pnpm-lock.yaml"
)

is_blocked() {
    local f="$1"
    local base; base="$(basename "$f")"
    local p
    for p in "${BLOCK_PATTERNS[@]}"; do
        # match against full path and against basename
        case "$f" in $p) return 0 ;; esac
        case "$base" in $p) return 0 ;; esac
    done
    return 1
}

CHANGED_FILES=$(git diff HEAD --name-only)
all_blocked=1
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! is_blocked "$f"; then
        all_blocked=0
        break
    fi
done <<< "$CHANGED_FILES"
(( all_blocked )) && exit 0
```

- [ ] **Step 4: 통과 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 모두 PASS. 합계 `11 passed, 0 failed`. exit 0.

- [ ] **Step 5: 커밋**

```bash
git add skills/fusion/lib/auto-review-hook.sh tests/auto-review-hook.test.sh
git commit -m "feat: 파일 패턴 blocklist 필터 추가

변경 파일이 모두 BLOCK 패턴(*.md, *.lock, *.json 등)이면
silent skip. Makefile이나 *.c처럼 BLOCK이 아닌 파일이 하나라도
있으면 진행. stub codex 호출 sentinel로 skip 여부 직접 검증."
```

---

### Task 4: diff 해시 캐시 필터 (TDD)

**Files:**
- Modify: `skills/fusion/lib/auto-review-hook.sh`
- Modify: `tests/auto-review-hook.test.sh`

- [ ] **Step 1: 실패 테스트 추가**

`tests/auto-review-hook.test.sh`의 마지막 `printf '\n%s passed...` 직전에 추가:

```bash
# --- cache cases ---

# (12) same diff hooked twice → second call: codex NOT called
cache_repo=$(prep_repo_with_files src/foo.c)
# first call: codex CALLED (cached after this)
sentinel1=$(mktemp -u); rm -f "$sentinel1"
out1="$(env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" CODEX_CALLED_SENTINEL="$sentinel1" \
    bash -c "cd '$cache_repo' && bash '$HOOK'" 2>/dev/null)"
exit1=$?
called1=no; [[ -e "$sentinel1" ]] && called1=yes; rm -f "$sentinel1"
# second call: same diff, codex NOT called
sentinel2=$(mktemp -u); rm -f "$sentinel2"
out2="$(env -i HOME="$HOME" PATH="$t_stub:/usr/bin:/bin" CODEX_CALLED_SENTINEL="$sentinel2" \
    bash -c "cd '$cache_repo' && bash '$HOOK'" 2>/dev/null)"
exit2=$?
called2=no; [[ -e "$sentinel2" ]] && called2=yes; rm -f "$sentinel2"
if [[ "$exit1" == "0" && "$called1" == "yes" && "$exit2" == "0" && "$called2" == "no" ]]; then
    PASS=$((PASS+1)); printf '  PASS: same diff twice → first calls codex, second silent\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: cache hit case (exit1=%s called1=%s exit2=%s called2=%s)\n' \
        "$exit1" "$called1" "$exit2" "$called2"
fi
[[ -f "$cache_repo/.fusion-cache.txt" ]] && \
    cache_lines=$(wc -l < "$cache_repo/.fusion-cache.txt") || cache_lines=0
if [[ "$cache_lines" -ge 1 ]]; then
    PASS=$((PASS+1)); printf '  PASS: .fusion-cache.txt has at least 1 hash entry\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: .fusion-cache.txt missing or empty\n'
fi
```

(이 추가 테스트는 task 5에서 codex 호출이 살아 있어야 첫 회 PASS. 따라서 task 4 step 4까지는 첫 회 codex 미호출이라 `called1=no`로 FAIL — 의도된 단계별 실패. task 5에서 강화.)

- [ ] **Step 2: 실패 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 캐시 케이스 2개 FAIL (codex가 task 5에서 wiring되므로 첫 회 호출 안 됨). 합계 PASS=11 FAIL=2. exit 1.

- [ ] **Step 3: 해시 캐시 로직 구현**

`auto-review-hook.sh`의 BLOCK 필터 블록 직후 (`exit 0` 직전)에 다음 추가:

```bash

# 4. Filter (d) — diff hash cache
PROJECT_ROOT=$(git rev-parse --show-toplevel)
CACHE_FILE="$PROJECT_ROOT/.fusion-cache.txt"
DIFF_HASH=$(printf '%s' "$DIFF_TEXT" | shasum -a 256 | awk '{print $1}')
if [[ -f "$CACHE_FILE" ]] && grep -qx "$DIFF_HASH" "$CACHE_FILE"; then
    exit 0
fi
```

(아직 cache write는 codex 호출 성공 시점에 — task 5에서 추가.)

- [ ] **Step 4: 통과 확인 (부분)**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 캐시 케이스 (12)는 여전히 task 5 의존이라 FAIL. (13) `.fusion-cache.txt` 존재 케이스도 FAIL. 합계 변동 없음 (`11 passed, 2 failed`). 이는 의도. **이 task의 검증 핵심**은 "캐시 hit 시 silent skip" 분기 *코드 자체가* 추가됐는지 — 다음 단계에서 cache write가 추가되면 자연스럽게 통과.

코드 추가가 정확한지 확인:
```bash
grep -c 'fusion-cache.txt' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/lib/auto-review-hook.sh
```
Expected: `1` (CACHE_FILE 정의 한 줄)

- [ ] **Step 5: 커밋**

```bash
git add skills/fusion/lib/auto-review-hook.sh tests/auto-review-hook.test.sh
git commit -m "feat: diff 해시 캐시 read 추가 (write는 다음 task)

git rev-parse --show-toplevel으로 PROJECT_ROOT 식별,
.fusion-cache.txt 에 SHA-256 hash 저장.
캐시 hit 시 silent exit 0. cache write는 codex 호출 성공
직후로 이동(다음 task)."
```

---

### Task 5: codex 호출 + VERDICT 파싱 + 출력 + 캐시 write (TDD)

**Files:**
- Modify: `skills/fusion/lib/auto-review-hook.sh`
- Modify: `tests/auto-review-hook.test.sh` (assert_called2 강화 + REVISE 케이스 추가)

- [ ] **Step 1: 강화된 테스트 적용**

`tests/auto-review-hook.test.sh`에서 task 3에 추가했던 다음 두 줄을 **수정**:

```bash
assert_called2 "Makefile + lock → reaches stage past pattern filter" 0 no "" "$mkmix" "$t_stub"
assert_called2 "only *.c → reaches stage past pattern filter" 0 no "" "$conly" "$t_stub"
```

수정 후:

```bash
assert_called2 "Makefile + lock → codex CALLED (APPROVED)" 0 yes "APPROVED" "$mkmix" "$t_stub"
assert_called2 "only *.c → codex CALLED (APPROVED)" 0 yes "APPROVED" "$conly" "$t_stub"
```

그리고 새로운 REVISE stub 디렉토리와 케이스를 파일 끝(캐시 케이스 직전)에 추가:

```bash
# (14) REVISE stub → severity counts in output
revise_stub=$(stub_codex_dir revise)
revise_repo=$(prep_repo_with_files src/bug.c)
assert_called2 "REVISE → 한 줄 + state 경로" 0 yes "REVISE" "$revise_repo" "$revise_stub"
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 강화된 (10)(11)(14)와 캐시 케이스가 FAIL (codex 미연결). 합계 PASS≈8 FAIL≈5. exit 1.

- [ ] **Step 3: codex 호출·출력·캐시 write 구현**

`auto-review-hook.sh`의 캐시 read 블록 직후, 그리고 마지막 `exit 0` 직전에 다음 코드 추가:

```bash

# 5. Codex call (single round, no PREV_HISTORY)
FUSION_TS=$(date +%s)
FUSION_RAND=$(printf '%04x' $((RANDOM)))
FUSION_DIR="/tmp/fusion-${FUSION_TS}-${FUSION_RAND}"
mkdir -p "$FUSION_DIR"

PREV_HISTORY="(none)"
TASK_TEXT="[auto-review] Stop hook 자동 리뷰. Working tree changes shown below."
PROMPT_FILE="$FUSION_DIR/round-1-prompt.txt"
LAST_MSG_FILE="$FUSION_DIR/round-1-codex.txt"

export TASK_TEXT PREV_HISTORY DIFF_TEXT
python3 - "$SKILL_DIR/prompts/reviewer.md" "$PROMPT_FILE" <<'PYEOF'
import sys, os
tmpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])
with open(out_path, "w") as f:
    f.write(s)
PYEOF

SECONDS=0
if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2> "$FUSION_DIR/round-1-codex.stderr"; then
    sleep 1
    if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2>> "$FUSION_DIR/round-1-codex.stderr"; then
        exit 0
    fi
fi
ELAPSED=$SECONDS

# 6. VERDICT parse
VERDICT=$(bash "$SKILL_DIR/lib/parse-verdict.sh" < "$LAST_MSG_FILE")

# 7. Cache write (only on a successful round)
echo "$DIFF_HASH" >> "$CACHE_FILE"
tail -n 100 "$CACHE_FILE" > "$CACHE_FILE.tmp" 2>/dev/null && mv "$CACHE_FILE.tmp" "$CACHE_FILE"

# 8. Output
case "$VERDICT" in
    APPROVED)
        echo "[fusion] ✓ auto-review APPROVED (${ELAPSED}s)"
        ;;
    REVISE)
        BLOCKERS=$(grep -c '^- BLOCKER:' "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        MAJORS=$(grep -c   '^- MAJOR:'   "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        MINORS=$(grep -c   '^- MINOR:'   "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        echo "[fusion] ⚠ auto-review REVISE — ${BLOCKERS} BLOCKER, ${MAJORS} MAJOR, ${MINORS} MINOR (state: $FUSION_DIR)"
        ;;
    *)
        exit 0
        ;;
esac
```

마지막 `exit 0`은 그대로 둠 (위 case 끝의 자연 fallthrough 대비).

- [ ] **Step 4: 통과 확인**

Run: `bash tests/auto-review-hook.test.sh`
Expected: 모든 케이스 PASS, exit 0.

케이스 합계 (정확 카운트): pre-check 3 + size 4 + pattern 4 + cache 2 + revise 1 = **14 passed, 0 failed**.

- [ ] **Step 5: 커밋**

```bash
git add skills/fusion/lib/auto-review-hook.sh tests/auto-review-hook.test.sh
git commit -m "feat: codex 호출·VERDICT 파싱·출력·캐시 write 통합

reviewer.md slot 치환(python heredoc), codex exec --sandbox
read-only -o, 1회 재시도 후 모두 실패시 silent. parse-verdict.sh
재사용. APPROVED는 한 줄 + 경과시간, REVISE는 BLOCKER/MAJOR/MINOR
카운트 + state 경로. 성공 라운드만 .fusion-cache.txt에 hash
append + tail -n 100 cap. stub codex로 14개 케이스 검증."
```

---

### Task 6: `enable-auto.sh` (settings.json 안전 병합 + 테스트)

**Files:**
- Create: `enable-auto.sh`
- Create: `tests/settings-merge.test.sh`

- [ ] **Step 1: 테스트 작성**

`tests/settings-merge.test.sh` 파일 전체 내용:

```bash
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

권한:
```bash
chmod +x tests/settings-merge.test.sh
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: 모든 케이스 FAIL (`enable-auto.sh` 없음). 합계 `0 passed, 6 failed`. exit 1.

- [ ] **Step 3: enable-auto.sh 작성**

`enable-auto.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Enable /fusion auto-review for the current (or given) project.
# - Adds Stop hook entry into <project>/.claude/settings.json (safe merge).
# - Adds .fusion-cache.txt to <project>/.gitignore.
# - Backs up settings.json to .bak before edit.

set -euo pipefail

PROJECT="${1:-$PWD}"
HOOK_CMD='bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh'
SETTINGS="$PROJECT/.claude/settings.json"
GITIGNORE="$PROJECT/.gitignore"

mkdir -p "$PROJECT/.claude"

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.bak"
else
    printf '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
hooks = data.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
# look for an existing entry that matches our command
already = False
for entry in stop:
    for h in entry.get("hooks", []):
        if h.get("command") == cmd:
            already = True
            break
    if already:
        break
if not already:
    stop.append({"hooks": [{"type": "command", "command": cmd}]})
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("noop" if already else "added")
PYEOF

# .gitignore: append .fusion-cache.txt if not present
if [[ -f "$GITIGNORE" ]]; then
    if ! grep -qx '.fusion-cache.txt' "$GITIGNORE"; then
        printf '\n.fusion-cache.txt\n' >> "$GITIGNORE"
    fi
else
    printf '.fusion-cache.txt\n' > "$GITIGNORE"
fi

echo "Auto-review enabled in $PROJECT. Use disable-auto.sh to turn off."
```

권한:
```bash
chmod +x enable-auto.sh
```

- [ ] **Step 4: 통과 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: 케이스 (1)~(5) PASS. (6) `.bak` 케이스는 빈 settings.json이 처음 생성된 케이스라 (3)에서 사용자 settings를 덮어쓰는 시점에 비로소 .bak 생성됨. 즉 (6)는 PASS여야 함. 합계 `6 passed, 0 failed`. exit 0.

만약 (6) FAIL이라면: enable-auto.sh가 빈 파일 생성 시점에 .bak을 만들지 않는 게 문제 — 이는 의도된 동작 (.bak은 *기존 파일* 백업용). 테스트 (6)에서 (3) 단계 직후 `.bak` 존재해야 함. (3)이 사용자 settings 작성 후 `enable`을 호출하므로 `cp .bak`은 그 시점에 실행됨. 따라서 (6) 시점엔 `.bak` 존재. PASS 기대.

- [ ] **Step 5: 커밋**

```bash
git add enable-auto.sh tests/settings-merge.test.sh
git commit -m "feat: enable-auto.sh 추가

.claude/settings.json에 Stop hook entry 안전 병합. 기존 사용자
hook entries 보존, 중복 방지 (정확 매칭). 기존 파일은 .bak로 백업.
.gitignore에 .fusion-cache.txt 라인 추가(중복 방지). 6개 케이스 검증."
```

---

### Task 7: `disable-auto.sh` (정확 제거 + 테스트)

**Files:**
- Create: `disable-auto.sh`
- Modify: `tests/settings-merge.test.sh` (disable 케이스 추가)

- [ ] **Step 1: 실패 테스트 추가**

`tests/settings-merge.test.sh` 끝의 `printf '\n%s passed...` 직전에 추가:

```bash
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
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: (7)(8)(9) FAIL (`disable-auto.sh` 없음). 합계 `6 passed, 3 failed`. exit 1.

- [ ] **Step 3: disable-auto.sh 작성**

`disable-auto.sh` 파일 전체 내용:

```bash
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

python3 - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
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

echo "Auto-review disabled."
```

권한:
```bash
chmod +x disable-auto.sh
```

- [ ] **Step 4: 통과 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: 모든 9개 케이스 PASS. 합계 `9 passed, 0 failed`. exit 0.

- [ ] **Step 5: 커밋**

```bash
git add disable-auto.sh tests/settings-merge.test.sh
git commit -m "feat: disable-auto.sh 추가

.claude/settings.json에서 fusion hook entry 정확 매칭으로 제거.
사용자 다른 entries 보존, 빈 객체 자동 정리, settings.json 자체
부재 시 graceful exit. 3개 케이스 검증 (총 9개)."
```

---

### Task 8: README "자동 리뷰" 섹션 추가

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README 업데이트**

`README.md`의 `## 후속 단계 로드맵` 섹션 직전에 다음 새 섹션 삽입:

```markdown
## 자동 리뷰 (Phase 2)

`Stop` hook으로 Claude의 응답이 끝날 때마다 Codex 리뷰 1라운드를 자동 실행합니다. 코드 자동 수정은 하지 않습니다 — REVISE 알림을 보고 사용자가 `/fusion`을 수동 호출해 핑퐁 진행 결정.

### Project-local opt-in

```bash
cd <your-project>
/path/to/CodexClaudeFusion/enable-auto.sh
```

이후 그 프로젝트에서 Claude의 응답이 끝나면 자동으로:
```
[fusion] ✓ auto-review APPROVED (6s)
```
또는
```
[fusion] ⚠ auto-review REVISE — 1 BLOCKER, 2 MAJOR, 0 MINOR (state: /tmp/fusion-...)
```

해제:
```bash
cd <your-project>
/path/to/CodexClaudeFusion/disable-auto.sh
```

### 노이즈 컨트롤

다음 조건 중 하나라도 해당하면 자동 리뷰는 silent skip:
- working tree 변경 없음
- diff 3줄 미만
- 변경 파일이 모두 blocklist (`*.md`, `*.lock`, `*.json`, `*.log`, `*.bak`, `package-lock.json` 등)
- 직전에 동일 diff를 이미 리뷰함 (`.fusion-cache.txt` 해시 캐시)

500줄 초과 변경은 한 줄 안내 후 skip — 수동 `/fusion` 권장.

### 검증 시나리오 (dogfooding)

| 시나리오 | 기대 결과 | 결과 |
|---|---|---|
| A1: opt-in → 작은 *.c 5줄 변경 → 응답 끝 | "[fusion] ✓ APPROVED" 1라인 | (추후 기록) |
| A2: opt-in → buggy *.c (off-by-one) → 응답 끝 | "[fusion] ⚠ REVISE — 1 MAJOR..." | (추후 기록) |
| A3: opt-in → README만 수정 | 패턴 필터로 silent | (추후 기록) |
| A4: 동일 diff로 두 번 응답 | 첫 회만 review, 둘째는 캐시 silent | (추후 기록) |
| A5: disable-auto.sh 후 변경 | hook 미등록, 출력 없음 | (추후 기록) |

```

- [ ] **Step 2: 새 섹션 삽입 검증**

Run:
```bash
grep -c '^## 자동 리뷰' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
```
Expected: `1`

Run:
```bash
grep -c '^| A[1-5]:' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
```
Expected: `5`

- [ ] **Step 3: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add README.md
git commit -m "docs: README에 자동 리뷰 섹션 추가

Phase 2 자동 리뷰 사용자 가이드. enable-auto.sh / disable-auto.sh
사용법, 한 줄 결과 출력 형식, 4종 노이즈 필터 안내, A1~A5
dogfooding 시나리오 표 (결과는 추후 기록)."
```

---

### Task 9: 통합 정적 검증

이 task는 새 파일을 만들지 않고 검증만 수행. 커밋 없음.

- [ ] **Step 1: bash 문법 검사**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
bash -n skills/fusion/lib/auto-review-hook.sh \
 && bash -n enable-auto.sh \
 && bash -n disable-auto.sh \
 && bash -n tests/auto-review-hook.test.sh \
 && bash -n tests/settings-merge.test.sh \
 && echo "all syntax OK"
```
Expected: `all syntax OK`

- [ ] **Step 2: 모든 테스트 재실행**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
bash tests/parse-verdict.test.sh && \
bash tests/auto-review-hook.test.sh && \
bash tests/settings-merge.test.sh
```
Expected: 모두 exit 0. parse-verdict 13/13, auto-review-hook 14/14 (또는 정확 합계), settings-merge 9/9 PASS.

- [ ] **Step 3: hook 경로 정합성**

Run:
```bash
grep -c '\$HOME/.claude/skills/fusion' /Users/jekim/01.Projects/11.CodexClaudeFusion/enable-auto.sh
grep -c '\$HOME/.claude/skills/fusion' /Users/jekim/01.Projects/11.CodexClaudeFusion/disable-auto.sh
test -x /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/lib/auto-review-hook.sh && echo "hook exec OK"
```
Expected: 각 ≥1, 마지막 `hook exec OK`

- [ ] **Step 4: Phase 1 산출물 무손 확인**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git diff 7b35362 -- skills/fusion/prompts/reviewer.md | head -1
git diff 7b35362 -- skills/fusion/lib/parse-verdict.sh | head -1
```
Expected: 둘 다 빈 출력 (Phase 1 파일 무변경).

- [ ] **Step 5: 변경 없음 확인**

Run: `git status --short`
Expected: 빈 출력.

이 task는 산출물·커밋 없음.

---

### Task 10: dogfooding (수동, 사용자 주도)

스펙 §9 "Phase 2 → Phase 3 진입 게이트". 시나리오 A1~A5 + 실전 펌웨어 1건. 사용자 환경에서 실제 codex 호출 + Claude Code 세션 필요. 결과를 README의 시나리오 표에 채워 commit.

- [ ] **Step 1: 본 레포에서 enable-auto.sh 시연**

Run:
```bash
cd /tmp
mkdir -p phase2-dogfood && cd phase2-dogfood
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
/Users/jekim/01.Projects/11.CodexClaudeFusion/enable-auto.sh
cat .claude/settings.json
cat .gitignore
```
Expected: settings.json에 hooks.Stop 안에 fusion entry, .gitignore에 `.fusion-cache.txt` 한 줄.

- [ ] **Step 2: A3 검증 (silent skip — 패턴 필터)**

`/tmp/phase2-dogfood`에 `note.md` 추가하고 hook 직접 실행:
```bash
cd /tmp/phase2-dogfood
echo "# note" > note.md
echo "more" >> note.md
echo "lines" >> note.md
echo "added" >> note.md
git add -N .
bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh
echo "exit=$?"
```
Expected: 출력 없음, exit 0.

- [ ] **Step 3: A1 검증 (APPROVED 시나리오)**

`/tmp/phase2-dogfood`에 작은 *.c 변경:
```bash
cd /tmp/phase2-dogfood
cat > foo.c <<'EOF'
#include <stdio.h>
int main(void) { printf("hello\n"); return 0; }
EOF
git add -N .
bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh
echo "exit=$?"
```
Expected: `[fusion] ✓ auto-review APPROVED (Ns)` 한 줄. exit 0.

- [ ] **Step 4: A4 검증 (캐시 hit)**

직전 호출 직후 동일 변경에서 다시:
```bash
bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh
echo "exit=$?"
```
Expected: 출력 없음 (캐시 hit), exit 0.

- [ ] **Step 5: A2 검증 (REVISE 시나리오)**

작은 *.c에 의도적 off-by-one 심기:
```bash
cd /tmp/phase2-dogfood
cat > buggy.c <<'EOF'
int sum(int *a, int n) {
    int s = 0;
    for (int i = 0; i <= n; i++) s += a[i];
    return s;
}
EOF
# .fusion-cache.txt 비우기 (이전 hash와 다른 diff라 캐시 영향 없음, 하지만 명시적으로)
> .fusion-cache.txt
bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh
echo "exit=$?"
```
Expected: `[fusion] ⚠ auto-review REVISE — N BLOCKER, M MAJOR, K MINOR (state: /tmp/fusion-...)` 한 줄. exit 0.

- [ ] **Step 6: A5 검증 (disable 후 미발동)**

```bash
cd /tmp/phase2-dogfood
/Users/jekim/01.Projects/11.CodexClaudeFusion/disable-auto.sh
cat .claude/settings.json
echo "extra" >> buggy.c
bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh
echo "exit=$?"
```
Expected: settings.json에서 우리 entry 사라짐. 단 hook 직접 호출이라 disable과 무관하게 동작 — 진정한 A5 검증은 Claude Code 세션에서 hook 자체가 발동하는지로 — 본 task에서는 settings.json 변화만 확인.

- [ ] **Step 7: 실전 펌웨어 dogfooding (선택, Phase 3 게이트)**

`athens-gate-fw` 또는 `GateReader`에 격리 worktree에서 enable-auto.sh → 작은 변경 → Claude Code 세션에서 응답 종료 → hook 발동 확인. 결과를 README A 표 또는 별도 항목에 기록.

- [ ] **Step 8: README 업데이트 + 커밋**

A1~A5 결과를 README의 시나리오 표 "결과" 열에 채워 넣고:

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add README.md
git commit -m "docs: Phase 2 dogfooding A1~A5 결과 기록

자동 리뷰 hook 실전 검증. silent skip(패턴), APPROVED 한 줄,
캐시 hit silent, REVISE 한 줄+state 경로, disable 후 미발동
모두 확인. Phase 2 인수 기준 충족."
```

- [ ] **Step 9: 정리**

```bash
rm -rf /tmp/phase2-dogfood
```

---

## Self-Review 체크리스트 (실행자가 모두 마친 뒤 점검)

- [ ] 스펙 §1~§11 각 절이 적어도 한 task로 다뤄졌는가
- [ ] hook의 4 필터(변경 없음/임계치/blocklist/캐시)가 §6 흐름과 정확히 일치
- [ ] reviewer.md 슬롯 이름 3종이 그대로 유지 (Phase 1 파일 무변경)
- [ ] codex 호출 옵션 `--skip-git-repo-check --sandbox read-only -o`이 Phase 1과 동일
- [ ] 모든 비정상 분기가 silent exit 0 (VERDICT 누락 포함)
- [ ] enable/disable이 사용자 기존 hook 보존 + .bak 백업
- [ ] .fusion-cache.txt가 .gitignore에 추가됨 (중복 방지)

---

**Plan 완료.** 저장 위치: `docs/superpowers/plans/2026-05-08-codex-claude-fusion-phase2.md`
