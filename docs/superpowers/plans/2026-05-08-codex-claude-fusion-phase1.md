# Codex–Claude Fusion (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude↔Codex 자동 핑퐁 검증을 1회 트리거로 실행하는 슬래시 스킬 `/fusion`을 빌드한다.

**Architecture:** 인-세션 슬래시 스킬. 작자=Claude(현재 세션), 검토자=Codex(`codex exec --sandbox read-only`로 별도 호출). 합의 신호는 Codex 마지막 메시지 끝 줄의 `VERDICT: APPROVED|REVISE` 마커, 안전망은 최대 N라운드 (기본 3).

**Tech Stack:** bash, `codex` CLI ≥ 0.128.0, `git`. 외부 의존 없음.

**Spec:** `docs/superpowers/specs/2026-05-08-codex-claude-fusion-design.md`

---

## File Structure

```
skills/fusion/
├── SKILL.md                  # 핑퐁 루프 명세 (Claude가 따라감)
├── prompts/
│   └── reviewer.md           # Codex에 주입할 시스템 프롬프트
└── lib/
    └── parse-verdict.sh      # 마지막 줄 VERDICT 마커 추출
tests/
└── parse-verdict.test.sh     # plain bash 테스트
install.sh                    # ~/.claude/skills/fusion 심볼릭 링크
README.md                     # 사용자 문서
```

각 파일 책임:
- `SKILL.md` — 사용자가 `/fusion`을 호출했을 때 Claude가 따라가는 단계별 지시
- `prompts/reviewer.md` — Codex가 검토자로서 받는 시스템 프롬프트 (슬롯 포함 템플릿)
- `lib/parse-verdict.sh` — 텍스트 입력에서 마지막 비어있지 않은 줄의 VERDICT 마커 추출 (단일 책임)
- `tests/parse-verdict.test.sh` — `parse-verdict.sh`의 정상·비정상 케이스 검증
- `install.sh` — 멱등적인 심볼릭 링크 생성/갱신
- `README.md` — 사용자 관점 설치·사용법·시나리오 문서

---

### Task 1: 프로젝트 골격 셋업

**Files:**
- Create: `skills/fusion/.keep`
- Create: `tests/.keep`
- Modify: `.gitignore` (이미 존재, 보강)

- [ ] **Step 1: 디렉토리 골격 생성**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
mkdir -p skills/fusion/prompts skills/fusion/lib tests
touch skills/fusion/.keep tests/.keep
```

- [ ] **Step 2: `.gitignore` 보강**

`.gitignore` 전체 내용을 다음으로 덮어쓴다:

```gitignore
.DS_Store
.claude/settings.local.json

# Fusion runtime artifacts (per-session temp dirs are under /tmp/, but be defensive)
fusion-*.tmp/
*.swp
```

- [ ] **Step 3: 변경 확인**

Run: `git status --short`
Expected:
```
 M .gitignore
?? skills/
?? tests/
```

- [ ] **Step 4: 커밋**

```bash
git add .gitignore skills/fusion/.keep tests/.keep
git commit -m "chore: 프로젝트 골격 디렉토리 생성

skills/fusion/{prompts,lib}, tests 디렉토리 자리 잡고
.gitignore에 fusion-*.tmp 보호 패턴 추가."
```

---

### Task 2: `parse-verdict.sh` (TDD)

**Files:**
- Create: `lib/parse-verdict.sh` ※ 실제 위치는 `skills/fusion/lib/parse-verdict.sh`
- Create: `tests/parse-verdict.test.sh`

스펙 §6.6: 입력 텍스트의 **마지막 비어있지 않은 줄**을 검사. `VERDICT: APPROVED` → stdout `APPROVED` exit 0; `VERDICT: REVISE` → stdout `REVISE` exit 0; 그 외 → stdout `UNKNOWN` exit 1.

- [ ] **Step 1: 실패 테스트 작성**

`tests/parse-verdict.test.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Plain bash test runner for parse-verdict.sh.
# Exit status: 0 if all pass, 1 if any fail.

set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/skills/fusion/lib/parse-verdict.sh"
FAIL=0
PASS=0

# Args: <description> <expected_stdout> <expected_exit> <input_text>
assert_case() {
    local desc="$1" expected_out="$2" expected_exit="$3" input="$4"
    local actual_out actual_exit
    actual_out="$(printf '%s' "$input" | bash "$SCRIPT" 2>/dev/null)"
    actual_exit=$?
    if [[ "$actual_out" == "$expected_out" && "$actual_exit" == "$expected_exit" ]]; then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s\n    expected: out=%q exit=%s\n    got:      out=%q exit=%s\n' \
            "$desc" "$expected_out" "$expected_exit" "$actual_out" "$actual_exit"
    fi
}

assert_case "approved on last line" \
    "APPROVED" "0" \
    "Some review text
More text
VERDICT: APPROVED"

assert_case "revise on last line" \
    "REVISE" "0" \
    "Issues found:
- BLOCKER: foo
VERDICT: REVISE"

assert_case "approved with trailing blank lines" \
    "APPROVED" "0" \
    "review
VERDICT: APPROVED


"

assert_case "marker not on last non-blank line is unknown" \
    "UNKNOWN" "1" \
    "VERDICT: APPROVED
some trailing chatter"

assert_case "no marker at all is unknown" \
    "UNKNOWN" "1" \
    "Just a normal review without verdict."

assert_case "lowercase verdict is unknown (we require exact)" \
    "UNKNOWN" "1" \
    "verdict: approved"

assert_case "extra spaces after colon is unknown (strict match)" \
    "UNKNOWN" "1" \
    "VERDICT:  APPROVED"

assert_case "leading whitespace on marker line is trimmed" \
    "APPROVED" "0" \
    "review text
   VERDICT: APPROVED"

assert_case "single-line approved input" \
    "APPROVED" "0" \
    "VERDICT: APPROVED"

assert_case "empty input is unknown" \
    "UNKNOWN" "1" \
    ""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

권한 부여:
```bash
chmod +x tests/parse-verdict.test.sh
```

- [ ] **Step 2: 테스트 실행해서 실패 확인**

Run: `bash tests/parse-verdict.test.sh`
Expected: 모든 케이스 FAIL (parse-verdict.sh가 아직 없음). 마지막 줄에 `0 passed, 10 failed` 또는 유사한 형태. 종료 코드 1.

- [ ] **Step 3: `parse-verdict.sh` 구현**

`skills/fusion/lib/parse-verdict.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Read text from stdin, locate the LAST non-blank line, and check whether
# (after stripping leading whitespace) it equals exactly one of:
#   "VERDICT: APPROVED"  -> stdout "APPROVED", exit 0
#   "VERDICT: REVISE"    -> stdout "REVISE",   exit 0
# Otherwise: stdout "UNKNOWN", exit 1.
#
# Strict matching: exact case, exactly one space after the colon, no trailing
# garbage on that line. The reviewer prompt asks for this exact format, so any
# deviation indicates a prompt failure that the caller must surface.

set -u

last_nonblank=""
while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim CR (in case of CRLF input from some terminals)
    line="${line%$'\r'}"
    # Update only if the line has at least one non-whitespace char
    if [[ -n "${line//[[:space:]]/}" ]]; then
        last_nonblank="$line"
    fi
done

# Strip leading whitespace from candidate
trimmed="${last_nonblank#"${last_nonblank%%[![:space:]]*}"}"

case "$trimmed" in
    "VERDICT: APPROVED")
        printf 'APPROVED\n'
        exit 0
        ;;
    "VERDICT: REVISE")
        printf 'REVISE\n'
        exit 0
        ;;
    *)
        printf 'UNKNOWN\n'
        exit 1
        ;;
esac
```

권한 부여:
```bash
chmod +x skills/fusion/lib/parse-verdict.sh
```

- [ ] **Step 4: 테스트 실행해서 통과 확인**

Run: `bash tests/parse-verdict.test.sh`
Expected: 모든 케이스 PASS, 마지막 줄 `10 passed, 0 failed`, 종료 코드 0.

- [ ] **Step 5: 커밋**

```bash
git add skills/fusion/lib/parse-verdict.sh tests/parse-verdict.test.sh
git commit -m "feat: VERDICT 마커 파서 + 테스트

stdin에서 마지막 비어있지 않은 줄을 검사하여
VERDICT: APPROVED / REVISE 정확 매칭 시 그 결과를,
그 외에는 UNKNOWN을 반환. plain bash 테스트로 10개 케이스 검증."
```

---

### Task 3: `prompts/reviewer.md` 작성

**Files:**
- Create: `skills/fusion/prompts/reviewer.md`

스펙 §6.2 골격을 그대로 옮긴 템플릿. 슬롯은 SKILL.md가 매 라운드 sed/bash heredoc으로 치환.

- [ ] **Step 1: 파일 작성**

`skills/fusion/prompts/reviewer.md` 파일 전체 내용:

```markdown
You are Codex, acting as the reviewer in a Claude↔Codex pingpong loop.
Author is Claude. You DO NOT modify code; you only review.

CONTEXT
- Task: {{TASK_OR_DIFF_MODE}}
- Previous rounds:
{{PREV_HISTORY_OR_EMPTY}}

CURRENT DIFF
```diff
{{GIT_DIFF_HEAD}}
```

OUTPUT FORMAT (strict)
1. Overview (1-3 lines).
2. Issues by severity. Use ONLY these labels and only the categories that apply:
   - BLOCKER: <file:line> — what — why — suggested fix
   - MAJOR:   <file:line> — what — why — suggested fix
   - MINOR:   <file:line> — what — why — suggested fix
   If no issues at all, write the single line: `No actionable issues.`
3. The FINAL line of your message MUST be EXACTLY one of:
   `VERDICT: APPROVED`
   `VERDICT: REVISE`
   No trailing punctuation. No extra spaces. Nothing after this line.

RULES
- APPROVED only when no BLOCKER and no MAJOR remain. Style preferences alone are NOT grounds for REVISE.
- Reference real lines from the diff. Do not invent code that is not shown.
- Do not propose patches as code blocks; describe the fix in prose.
- Keep the review focused on the current diff; do not request unrelated refactors.
```

- [ ] **Step 2: 슬롯 토큰 검증**

Run: `grep -c '{{[A-Z_]\+}}' skills/fusion/prompts/reviewer.md`
Expected: `3` (TASK_OR_DIFF_MODE, PREV_HISTORY_OR_EMPTY, GIT_DIFF_HEAD)

- [ ] **Step 3: 커밋**

```bash
git add skills/fusion/prompts/reviewer.md
git commit -m "feat: Codex 리뷰어 프롬프트 템플릿 추가

read-only 검토자 역할, BLOCKER/MAJOR/MINOR 심각도 분류,
마지막 줄 VERDICT: APPROVED|REVISE 마커 강제.
3개 슬롯({{TASK_OR_DIFF_MODE}}, {{PREV_HISTORY_OR_EMPTY}}, {{GIT_DIFF_HEAD}}) 정의."
```

---

### Task 4: `SKILL.md` 핑퐁 루프 명세

**Files:**
- Create: `skills/fusion/SKILL.md`

스펙 §5 전체를 Claude가 그대로 따라갈 수 있는 단계별 지시문으로 풀어쓴다. Frontmatter 필수.

- [ ] **Step 1: 파일 작성**

`skills/fusion/SKILL.md` 파일 전체 내용:

````markdown
---
name: fusion
description: Claude↔Codex 자동 핑퐁 검증. /fusion <task>로 작업+검증을, /fusion 단독으로 현재 working tree diff 검증을 수행. 작자=Claude, 검토자=Codex 고정 역할로 합의(VERDICT: APPROVED) 또는 최대 N라운드까지 반복. 펌웨어/일반 코드 검토에 사용.
---

# /fusion — Claude↔Codex 핑퐁 검증

너(Claude)는 작자(author) 역할을 맡는다. Codex는 검토자(reviewer)로 read-only 모드에서만 동작한다. 코드 수정은 오직 너만 한다.

## 0. 사전 점검 (반드시 첫 단계)

다음을 확인해서 하나라도 실패하면 즉시 사용자에게 보고하고 종료한다:

```bash
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex CLI 미설치"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: git 레포 외부에서는 동작하지 않음"; exit 1; }
```

세션 디렉토리 만들기:

```bash
FUSION_TS=$(date +%s)
FUSION_RAND=$(printf '%04x' $((RANDOM)))
FUSION_DIR="/tmp/fusion-${FUSION_TS}-${FUSION_RAND}"
mkdir -p "$FUSION_DIR"
echo "fusion state: $FUSION_DIR"
```

## 1. 입력 파싱

사용자 호출 형태:
- `/fusion` → **diff 모드**: 현재 working tree(`git diff HEAD`)를 검증
- `/fusion <task description>` → **task 모드**: 너가 1차 구현 후 검증 시작
- 옵션: `--max-rounds N` (기본 3), `--files <glob>` (선택)

판정 + 변수 셋업:
- task 인자가 있으면 `MODE=task`, 없으면 `MODE=diff`
- task 모드면 task 텍스트를 `$FUSION_DIR/task.txt`에 저장
- `--max-rounds N` 파싱:
  ```bash
  MAX_ROUNDS=3
  # 사용자 입력에서 --max-rounds N이 있으면 N으로 덮어쓴다.
  # task 텍스트와 옵션을 분리해서 처리할 것. 예시:
  #   /fusion --max-rounds 5 작업 설명...   →  MAX_ROUNDS=5, TASK="작업 설명..."
  ```
- `--files <glob>`은 Phase 1에서는 정보성으로만 다룸 (파싱은 하되 동작은 전체 diff 그대로)

## 2. 작자 라운드 (task 모드일 때만)

너가 task 묘사대로 Edit/Write 도구로 1차 구현한다. 구현 후 working tree에 변경이 있어야 한다.

```bash
git add -N .   # untracked 파일을 git diff HEAD에 포함시키기 위해
if [[ -z "$(git diff HEAD)" ]]; then
    echo "ERROR: 작자 라운드에서 코드 변경이 발생하지 않음. task가 모호한지 확인."
    exit 1
fi
```

diff 모드면 이 단계를 건너뛴다. 단, working tree가 깨끗하면(`git diff HEAD`가 비어 있으면) 즉시 안내 후 종료:

```bash
if [[ -z "$(git diff HEAD)" ]]; then
    echo "변경사항 없음 — 검증할 diff가 없습니다."
    exit 0
fi
```

## 3. 라운드 루프

`MAX_ROUNDS=3` (또는 사용자가 `--max-rounds`로 지정한 값). `round=1..MAX_ROUNDS` 까지 반복:

### 3.a 검토자 라운드 — Codex 호출

이전 라운드 히스토리 모으기:

```bash
PREV_HISTORY=""
for ((i=1; i<round; i++)); do
    if [[ -f "$FUSION_DIR/round-${i}-claude.txt" ]]; then
        PREV_HISTORY+="Round ${i} — Claude reply: $(cat "$FUSION_DIR/round-${i}-claude.txt")"$'\n'
    fi
done
[[ -z "$PREV_HISTORY" ]] && PREV_HISTORY="(none)"
```

프롬프트 합성 (slot 치환):

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/prompts/reviewer.md"

# Use python3 for safe substitution (avoids shell metachar issues with diffs)
TASK_TEXT="$([[ "$MODE" == "task" ]] && cat "$FUSION_DIR/task.txt" || echo "[diff-mode] Review the working tree changes shown below.")"
DIFF_TEXT="$(git diff HEAD)"

PROMPT_FILE="$FUSION_DIR/round-${round}-prompt.txt"
export TASK_TEXT PREV_HISTORY DIFF_TEXT
python3 - "$TEMPLATE" "$PROMPT_FILE" <<'PYEOF'
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
```

(`export`로 자식 프로세스에 환경변수를 전달. heredoc은 `'PYEOF'` 따옴표로 셸 expansion을 차단해 코드가 그대로 들어가도록 함.)

Codex 호출:

```bash
LAST_MSG_FILE="$FUSION_DIR/round-${round}-codex.txt"
if ! codex exec \
        --skip-git-repo-check \
        --sandbox read-only \
        -o "$LAST_MSG_FILE" \
        - < "$PROMPT_FILE" 2> "$FUSION_DIR/round-${round}-codex.stderr"; then
    # 1회 재시도
    sleep 1
    if ! codex exec \
            --skip-git-repo-check \
            --sandbox read-only \
            -o "$LAST_MSG_FILE" \
            - < "$PROMPT_FILE" 2>> "$FUSION_DIR/round-${round}-codex.stderr"; then
        echo "ERROR: codex exec 두 번 모두 실패. stderr는 $FUSION_DIR/round-${round}-codex.stderr"
        exit 1
    fi
fi
```

### 3.b VERDICT 파싱

```bash
VERDICT=$(bash "$SCRIPT_DIR/lib/parse-verdict.sh" < "$LAST_MSG_FILE")
case "$VERDICT" in
    APPROVED)
        echo "== Round $round / $MAX_ROUNDS =="
        echo "Codex review: VERDICT: APPROVED"
        echo "✅ FUSION COMPLETE in $round rounds (state: $FUSION_DIR)"
        printf 'APPROVED in round %d\n' "$round" > "$FUSION_DIR/final.txt"
        exit 0
        ;;
    REVISE)
        echo "== Round $round / $MAX_ROUNDS =="
        echo "Codex review: VERDICT: REVISE (자세히는 $LAST_MSG_FILE)"
        ;;
    *)
        echo "ERROR: Codex 출력에 VERDICT 마커 누락. 프롬프트 실패 가능성."
        echo "출력: $LAST_MSG_FILE"
        exit 1
        ;;
esac
```

### 3.c 작자 응답 라운드 — 너(Claude)

`$LAST_MSG_FILE`을 읽고:
1. 각 BLOCKER / MAJOR / MINOR 항목을 검토
2. **무조건 수용 금지** — 명백히 잘못되거나 정책에 어긋나는 지적은 거부
3. 수용한 항목은 Edit/Write 도구로 코드 수정 (scope creep 금지: 새 기능 추가 안 함, 피드백 반영만)
4. 한 줄 요약을 다음 형식으로 작성:

```
applied: <수용한 항목 라벨>
rejected: <기각 항목 라벨> — reason: <한 줄 이유>
```

이 요약을 `$FUSION_DIR/round-${round}-claude.txt`에 저장:

```bash
cat > "$FUSION_DIR/round-${round}-claude.txt" <<'EOF'
applied: BLOCKER #1 (null check)
rejected: MINOR #2 — reason: 기존 매크로 정책과 충돌
EOF
```

(라운드마다 실제 적용/기각 내용을 채울 것)

이후 다음 라운드로 계속.

## 4. MAX_ROUNDS 도달 처리

루프가 끝났는데 APPROVED가 아니면:

```bash
echo "⚠️ MAX ROUNDS REACHED ($MAX_ROUNDS)"
echo "마지막 Codex 출력: $LAST_MSG_FILE"
echo "미해결 BLOCKER/MAJOR 항목을 사용자가 수동으로 검토하세요."
printf 'MAX_ROUNDS reached at %d\n' "$MAX_ROUNDS" > "$FUSION_DIR/final.txt"
exit 1
```

## 5. Red Flags — 절대 하지 말 것

- ❌ Codex 피드백을 무조건 적용 — 잘못된 지적은 거부하고 이유 기록
- ❌ 작자 응답 라운드에서 새 기능 추가 — 피드백 반영 외 변경 금지
- ❌ VERDICT 마커가 없을 때 자체 판단으로 분류 — 즉시 명시적 에러로 종료
- ❌ working tree를 commit/stash로 변형 — 사용자 git 흐름 보존
- ❌ Codex가 직접 파일 수정하도록 sandbox 풀기 — 항상 `--sandbox read-only`

## 6. 성공·실패 신호 정리

| 결과 | exit | 표시 |
|---|---|---|
| APPROVED 도달 | 0 | `✅ FUSION COMPLETE in N rounds` |
| MAX_ROUNDS 도달, 미해결 | 1 | `⚠️ MAX ROUNDS REACHED` |
| codex 미설치, git 외부 | 1 | `ERROR: ...` |
| VERDICT 마커 없음 | 1 | `ERROR: VERDICT 마커 누락` |
| diff 모드, 변경 없음 | 0 | `변경사항 없음 — 검증할 diff가 없습니다.` |
| codex exec 2회 실패 | 1 | `ERROR: codex exec 두 번 모두 실패` |
````

- [ ] **Step 2: frontmatter 검증**

Run: `head -4 skills/fusion/SKILL.md`
Expected: `---`로 시작, `name: fusion`, `description: ...`, `---`로 끝.

- [ ] **Step 3: 외부 참조 무결성 확인**

Run:
```bash
grep -c 'parse-verdict.sh' skills/fusion/SKILL.md
grep -c 'prompts/reviewer.md' skills/fusion/SKILL.md
test -x skills/fusion/lib/parse-verdict.sh && echo "parse-verdict executable OK"
```
Expected: 둘 다 ≥1, 마지막은 `parse-verdict executable OK`.

- [ ] **Step 4: 커밋**

```bash
git add skills/fusion/SKILL.md
git commit -m "feat: /fusion 슬래시 스킬 명세 추가

작자=Claude, 검토자=Codex 고정 역할의 핑퐁 루프 명세.
사전 점검(codex/git), 입력 파싱(task/diff 모드),
라운드 루프(검토→파싱→응답), MAX_ROUNDS 안전망,
Red Flags 가이드, 성공·실패 exit 신호표 포함."
```

---

### Task 5: `install.sh` (멱등 심볼릭 링크)

**Files:**
- Create: `install.sh`

`~/.claude/skills/fusion`이 본 레포의 `skills/fusion`을 가리키도록 심볼릭 링크. 멱등(이미 올바른 링크면 no-op, 다른 곳을 가리키면 안전 경고).

- [ ] **Step 1: 파일 작성**

`install.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Install /fusion skill by symlinking ~/.claude/skills/fusion to this repo's skills/fusion.
# Idempotent: noop if link is already correct; refuses to overwrite a non-symlink.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO_DIR/skills/fusion"
DEST_PARENT="$HOME/.claude/skills"
DEST="$DEST_PARENT/fusion"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: source not found: $SRC" >&2
    exit 1
fi

mkdir -p "$DEST_PARENT"

if [[ -L "$DEST" ]]; then
    current="$(readlink "$DEST")"
    if [[ "$current" == "$SRC" ]]; then
        echo "OK: $DEST already points to $SRC (no change)"
        exit 0
    fi
    echo "REPLACING symlink: $DEST"
    echo "  was -> $current"
    echo "  now -> $SRC"
    rm "$DEST"
elif [[ -e "$DEST" ]]; then
    echo "ERROR: $DEST exists but is not a symlink. Refusing to overwrite." >&2
    echo "       Move or remove it manually, then re-run." >&2
    exit 1
fi

ln -s "$SRC" "$DEST"
echo "INSTALLED: $DEST -> $SRC"
echo "이제 Claude Code에서 /fusion 사용 가능합니다."
```

권한 부여:
```bash
chmod +x install.sh
```

- [ ] **Step 2: 드라이런 검증 (실제 실행은 사용자에게 맡김)**

Run: `bash -n install.sh && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 3: 커밋**

```bash
git add install.sh
git commit -m "feat: install.sh 추가

~/.claude/skills/fusion 심볼릭 링크를 본 레포의 skills/fusion에 연결.
멱등 동작: 이미 올바른 링크면 no-op, 다른 링크면 교체,
일반 파일·디렉토리면 안전을 위해 거부."
```

---

### Task 6: `README.md` 작성

**Files:**
- Create: `README.md`

사용자가 처음 만났을 때 설치·사용·시나리오를 한눈에 보도록.

- [ ] **Step 1: 파일 작성**

`README.md` 파일 전체 내용:

````markdown
# Codex–Claude Fusion

Claude와 Codex가 한 번의 트리거로 자동 핑퐁 검증을 수행하는 슬래시 스킬 `/fusion`.

작자=Claude, 검토자=Codex 고정 역할로 코드를 합의(`VERDICT: APPROVED`)하거나 최대 N라운드까지 반복합니다. Phase 1 MVP — hook 자동화·펌웨어 룰셋·디버깅 통합은 후속 단계.

## 요구사항

- `codex` CLI ≥ 0.128.0
- `git`
- `bash`, `python3` (slot 치환에 사용)
- Claude Code 환경

## 설치

```bash
git clone <repo-url> CodexClaudeFusion
cd CodexClaudeFusion
./install.sh
```

이후 Claude Code 어느 프로젝트에서나 `/fusion`을 사용할 수 있습니다.

## 사용법

### task 모드 — 작업과 검증을 한꺼번에

```
/fusion C로 ring buffer push 함수를 작성해줘
```

Claude가 1차 구현한 뒤, Codex가 검토하고 합의될 때까지 핑퐁합니다.

### diff 모드 — 이미 만든 변경에 대해 검증

이미 working tree에 수정사항이 있을 때:

```
/fusion
```

`git diff HEAD` 결과를 Codex가 검토하고, Claude가 피드백을 반영하는 라운드를 돌립니다.

### 옵션

- `--max-rounds N` — 안전망 최대 라운드 수 (기본 3)
- `--files <glob>` — 특정 파일에 한정 (선택)

## 결과 확인

각 세션은 임시 디렉토리 `/tmp/fusion-<ts>-<rand>/` 에 라운드별 산출물을 보존합니다:

- `task.txt` — task 모드 입력
- `round-N-prompt.txt` — Codex에 보낸 합성 프롬프트
- `round-N-codex.txt` — Codex 마지막 메시지
- `round-N-claude.txt` — Claude의 수용/기각 한 줄 요약
- `final.txt` — APPROVED in round N 또는 MAX_ROUNDS reached at N

## 합의 신호

Codex는 마지막 줄에 다음 중 하나를 출력하도록 프롬프트로 강제됩니다:

- `VERDICT: APPROVED` — 합의 도달, 즉시 종료
- `VERDICT: REVISE` — Claude가 피드백 반영 후 다음 라운드

마커가 누락되면 즉시 명시적 에러로 종료합니다 (자체 판단으로 분류하지 않음).

## 검증 시나리오 (dogfooding)

| 시나리오 | 기대 결과 | 결과 |
|---|---|---|
| S1: task 모드 — "C로 ring buffer push" | 1~2 라운드 내 APPROVED | (기록 예정) |
| S2: diff 모드 — 의도적 off-by-one 버그 | Codex가 BLOCKER로 잡고 수정 후 APPROVED | (기록 예정) |
| S3: 이미 잘 짜인 코드에 `/fusion` | 1라운드 즉시 APPROVED | (기록 예정) |
| S4: 양립 불가 요구사항 강제 | MAX_ROUNDS 도달, 미해결 이슈 보고 | (기록 예정) |
| S5: `codex` 미설치 환경 | 명시적 에러, 라운드 진입 없음 | (기록 예정) |

## 디자인 문서

- 스펙: `docs/superpowers/specs/2026-05-08-codex-claude-fusion-design.md`
- 구현 계획: `docs/superpowers/plans/2026-05-08-codex-claude-fusion-phase1.md`

## 후속 단계 로드맵

- **Phase 2**: PostToolUse hook 자동 트리거
- **Phase 3**: 펌웨어 특화 룰셋 (ARM/embedded, ISR, watchdog)
- **Phase 4**: systematic-debugging / TDD 통합

## 라이선스

(미정)
````

- [ ] **Step 2: 커밋**

```bash
git add README.md
git commit -m "docs: README 추가

요구사항, 설치 절차, task/diff 두 모드 사용법,
세션 결과 디렉토리 구조, VERDICT 합의 신호, 시나리오 표,
후속 Phase 로드맵 안내."
```

---

### Task 7: 단위 테스트 재실행 + 정적 검증

각 산출물이 형식상 올바른지 통합 검증.

- [ ] **Step 1: bash 문법 검사**

Run:
```bash
bash -n install.sh
bash -n skills/fusion/lib/parse-verdict.sh
bash -n tests/parse-verdict.test.sh
echo "all syntax OK"
```
Expected: `all syntax OK`

- [ ] **Step 2: parse-verdict 테스트 재실행**

Run: `bash tests/parse-verdict.test.sh`
Expected: `10 passed, 0 failed`

- [ ] **Step 3: 슬롯 토큰 검사**

Run: `grep -o '{{[A-Z_]\+}}' skills/fusion/prompts/reviewer.md | sort -u`
Expected (정확히 3줄):
```
{{GIT_DIFF_HEAD}}
{{PREV_HISTORY_OR_EMPTY}}
{{TASK_OR_DIFF_MODE}}
```

- [ ] **Step 4: SKILL.md frontmatter 파싱 검증**

Run:
```bash
python3 -c "
import re, sys
with open('skills/fusion/SKILL.md') as f:
    txt = f.read()
m = re.match(r'^---\n(.*?)\n---\n', txt, re.S)
assert m, 'frontmatter not found'
fm = m.group(1)
assert 'name: fusion' in fm, 'name missing'
assert 'description:' in fm, 'description missing'
print('frontmatter OK')
"
```
Expected: `frontmatter OK`

- [ ] **Step 5: install.sh 멱등성 드라이런**

(환경 영향이 있으니 실제 실행은 사용자가 결정. 여기서는 syntax 및 변수 expansion만 점검.)
Run: `bash -n install.sh && echo "install syntax OK"`
Expected: `install syntax OK`

- [ ] **Step 6: 통합 검증 결과 커밋이 필요한 변경 없음 확인**

Run: `git status --short`
Expected: 빈 출력 (Task 1~6에서 이미 모두 커밋됨)

이 task는 산출물을 만들지 않고 검증만 하므로 커밋 없음.

---

### Task 8: 실전 dogfooding (수동, 결과 기록)

스펙 §8.3 인수 기준. 시나리오 5개를 실제 실행하고 결과를 README의 표에 채워 넣어 커밋.

이 task는 실행 환경(설치된 codex 인증 상태, 임의의 펌웨어 레포 등)에 의존하므로 **실행자가 직접 수행**하고, 결과 표만 README에 채운 뒤 commit한다.

- [ ] **Step 1: 본 레포에 `/fusion`을 설치**

Run: `./install.sh`
Expected: `INSTALLED: ~/.claude/skills/fusion -> .../skills/fusion` 또는 `OK: ... already points to ...`.

- [ ] **Step 2: S5부터 실행 (가장 안전)**

`codex` PATH를 일시 가리고 진입 점검이 동작하는지:

```bash
PATH="" /bin/bash -lc 'command -v codex || echo "codex not on PATH"'
```

S5는 `/fusion` 안에서 사전 점검 실패가 나는지를 보는 것이지만, 슬래시 스킬 호출은 Claude Code 세션 안에서 실행되므로 직접 PATH 조작은 어렵다. 대신 **사전 점검 블록만 따로 실행**:

```bash
# S5 simulation
PATH="/usr/bin:/bin" bash -lc 'command -v codex >/dev/null 2>&1 || echo "ERROR: codex CLI 미설치"'
```
Expected: `ERROR: codex CLI 미설치` (PATH가 codex 없는 상태일 때)

- [ ] **Step 3: S3 실행 (가장 가벼움)**

이미 잘 짜인 작은 변경 (예: README의 오탈자 한 글자 수정)을 working tree에 두고:

```
/fusion
```

Expected: 1라운드에 `VERDICT: APPROVED`, `✅ FUSION COMPLETE in 1 rounds`.

`/tmp/fusion-*/final.txt` 내용을 README S3 행에 기록 (예: "✅ APPROVED in round 1, ~12s").

- [ ] **Step 4: S1 실행**

워크트리 깨끗한 상태에서:

```
/fusion C로 16바이트 고정크기 ring buffer push 함수를 작성해줘 (단일 헤더, static inline)
```

Expected: 1~2 라운드 내 APPROVED. 라운드 수와 경과 시간을 README S1 행에 기록.

- [ ] **Step 5: S2 실행**

작은 C 함수 파일을 작성하고 의도적으로 off-by-one 버그를 심은 뒤 (예: `for (i=0; i<=N; i++)` 형태) `/fusion`.
Expected: round-1에서 Codex가 BLOCKER로 잡음, round-2에서 수정, round-2 또는 3 APPROVED. 결과를 README S2에 기록.

- [ ] **Step 6: S4 실행**

양립 불가 요구사항을 task로 던진다. 예:
```
/fusion 이 함수가 `malloc`을 절대 사용하지 않으면서, 동시에 동적 길이 입력을 다루는 가변 배열을 반환하도록 만들어줘 — VLA도 사용 금지.
```

`--max-rounds 2`로 짧게 강제:
```
/fusion --max-rounds 2 ...
```

Expected: MAX_ROUNDS 도달, `⚠️ MAX ROUNDS REACHED`, exit 1. 결과를 README S4에 기록.

- [ ] **Step 7: 실전 펌웨어 레포 dogfooding (인수 기준)**

`athens-gate-fw` 또는 `GateReader` 레포의 작은 실제 변경 1건에 `/fusion` 적용. 별도 디렉토리에서 수행.

결과 (round 수, 합의 도달 여부, 사용자 만족도)를 README 끝에 "Real-world acceptance" 항목으로 추가.

- [ ] **Step 8: README 업데이트 커밋**

```bash
git add README.md
git commit -m "docs: dogfooding 시나리오 결과 기록 (Phase 1 인수)

S1~S5 + 실전 펌웨어 레포 1건 dogfooding 결과를 README에 기록.
Phase 1 MVP 인수 기준 충족 → Phase 2(hook 자동화) 착수 가능 표식."
```

---

## Self-Review 체크리스트 (실행자가 모두 마친 뒤 점검)

- [ ] 스펙 §1~§10 각 절이 적어도 한 task로 다뤄졌는가
- [ ] `parse-verdict.sh` 동작이 §6.6과 일치하는가 (마지막 비어있지 않은 줄, 정확 매칭, exit 코드)
- [ ] `reviewer.md`의 슬롯 이름 3개가 SKILL.md의 치환 코드와 정확히 일치하는가
- [ ] SKILL.md의 Red Flags가 스펙 §5.3 가드레일을 모두 포함하는가
- [ ] codex 호출 시 항상 `--sandbox read-only`가 들어가는가 (Codex 직접 수정 차단)
- [ ] working tree에 `commit`/`stash`를 강요하지 않는가 (사용자 git 흐름 보존)
- [ ] 임시 디렉토리 경로가 종료 시 사용자에게 노출되는가 (사후 검토 가능성)

---

**Plan 완료.** 저장 위치: `docs/superpowers/plans/2026-05-08-codex-claude-fusion-phase1.md`
