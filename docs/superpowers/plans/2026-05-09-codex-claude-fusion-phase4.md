# Codex–Claude Fusion (Phase 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 새 슬래시 `/fusion-debug`로 systematic-debugging 협업 모드를 빌드한다 — Claude=가설·실행·fix, Codex=반증·누락 가설 제안.

**Architecture:** Phase 1 인프라(`parse-verdict.sh`, `reviewer.md`, severity 분류, VERDICT 마커) 무변경 재사용. 새 SKILL.md(`skills/fusion-debug/SKILL.md`)가 base reviewer.md + `debug-rules.md` (필수) + `firmware-rules.md` (Phase 3 활성 시) 합성. install.sh가 새 심볼릭 링크 추가.

**Tech Stack:** bash, python3, `codex` CLI ≥ 0.128.0, `git`. 외부 의존 없음.

**Spec:** `docs/superpowers/specs/2026-05-09-codex-claude-fusion-phase4-design.md` (커밋 49b8e54)

---

## File Structure

```
skills/fusion/                          # Phase 1·2·3 (모두 무변경)
├── SKILL.md
├── prompts/
│   ├── reviewer.md                     # base
│   ├── firmware-rules.md               # Phase 3
│   └── debug-rules.md                  # NEW: Phase 4
└── lib/parse-verdict.sh

skills/fusion-debug/                    # NEW
└── SKILL.md                            # NEW: /fusion-debug 진입점

tests/
└── debug-mode.test.sh                  # NEW: 4 케이스

install.sh                               # 변경: fusion-debug 심볼릭 링크 추가
README.md                                # 변경: "디버깅 모드 (Phase 4)" 섹션
```

각 파일 책임:
- `debug-rules.md`: Codex가 디버깅 라운드에 적용하는 룰셋 (3축: 가설 품질·실험 엄밀성·fix 정확성)
- `fusion-debug/SKILL.md`: `/fusion-debug` 진입 시 Claude가 따르는 명세 (사전점검·입력파싱·라운드루프). Phase 1 SKILL.md의 변형
- `debug-mode.test.sh`: SKILL.md의 prompt 합성 분기를 시뮬레이션해 prompt 파일 검사
- `install.sh`: 기존 fusion 링크 + 새 fusion-debug 링크 모두 멱등 관리

---

### Task 1: `debug-rules.md` 작성

**Files:**
- Create: `skills/fusion/prompts/debug-rules.md`

- [ ] **Step 1: 파일 작성**

`skills/fusion/prompts/debug-rules.md` 파일 전체 내용 (정확히 그대로):

```
DEBUGGING-MODE REVIEW RULES (active when invoked via /fusion-debug)

This invocation is a systematic-debugging round. Reinterpret base rules:

- "CURRENT DIFF" represents the code state under investigation
  (hypothesis-driven changes, instrumentation, or proposed fix). Do not
  judge it as a normal code review.
- VERDICT: APPROVED means "root cause sufficiently identified; proposed
  fix (if any) addresses it; no further hypothesis exploration needed."
- VERDICT: REVISE means "more hypotheses or experiments required."

Evaluate the author's (Claude's) work on three axes:

1. Hypothesis quality
   - Stated hypotheses must be concrete (causally specific, not vague).
   - Each hypothesis tested with the simplest experiment that would
     falsify it.
   - Propose any hypothesis the author missed but the symptom/diff
     suggests.
   → MAJOR if a critical hypothesis is missing, or a hypothesis was
     claimed validated without falsification evidence.

2. Experiment rigor
   - Experiment must aim to falsify, not confirm (confirmation bias is
     the main hazard).
   - Minimal: touches only the variable under test.
   - Result distinguishes the hypothesis from alternatives.
   → MAJOR if the experiment cannot falsify; MINOR if overly broad
     (touches too many variables).

3. Fix correctness (when a fix is proposed)
   - Fix addresses the verified root cause, not a symptom.
   - No silent-failure paths (defensive code hiding the real bug).
   - No regressions in unrelated paths.
   → BLOCKER if the fix masks the root cause or introduces regressions.

When fusion.firmware = true is also active, both rule sets apply — use
the firmware-rules prefix `(A.ISR)` / `(B.VOL)` for those issues.

Output format unchanged: severity label (with optional category prefix
in parens), final line `VERDICT: APPROVED` or `VERDICT: REVISE`.
Style preferences alone are NOT grounds for REVISE.
```

- [ ] **Step 2: 슬롯 토큰 부재 검증**

```bash
grep -c '{{[A-Z_]\+}}' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/debug-rules.md
```
Expected: `0`

- [ ] **Step 3: 길이·구조 sanity**

```bash
wc -l /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/debug-rules.md
grep -c 'Hypothesis quality' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/debug-rules.md
grep -c 'Experiment rigor' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/debug-rules.md
grep -c 'Fix correctness' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/debug-rules.md
```
Expected: 35~45줄, 각 항목 1.

- [ ] **Step 4: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add skills/fusion/prompts/debug-rules.md
git commit -m "feat: 디버깅 룰셋 (debug-rules.md) 추가

systematic-debugging 협업의 3축(가설 품질·실험 엄밀성·fix 정확성)
룰. base reviewer.md의 BLOCKER/MAJOR/MINOR 의미를 디버깅 컨텍스트로
재해석. firmware mode와 직교 — 둘 다 활성 시 prefix 그대로 적용."
```

---

### Task 2: `tests/debug-mode.test.sh` + `skills/fusion-debug/SKILL.md` (TDD)

**Files:**
- Create: `tests/debug-mode.test.sh`
- Create: `skills/fusion-debug/SKILL.md`

테스트는 SKILL.md의 prompt 합성 단계를 시뮬레이션 (Phase 3 firmware-mode.test.sh 패턴). 임시 git 레포 + 임시 home dir에 fusion-debug, fusion 둘 다 셋업하고 prompt 파일 합성 결과 검사.

핵심: SKILL.md는 LLM-readable 명세지만 *그 안의 prompt 합성 bash + python heredoc*은 그대로 실행 가능. 테스트는 SKILL.md를 source로 가져오는 대신 동일한 합성 코드를 인라인으로 실행해 결과 prompt 파일을 만들고 검사.

- [ ] **Step 1: 실패 테스트 작성**

`tests/debug-mode.test.sh` 파일 전체 내용:

```bash
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
# remove the symlinked debug-rules.md from the isolated home's view by
# replacing the fusion symlink with a copy that lacks debug-rules.md
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

# (4) fusion-debug symlink missing → SKILL.md cannot be invoked
# (Verify by absence of fusion-debug skill dir in HOME — the SKILL.md test
# is structural: just confirm the symlink path resolves.)
home4=$(mk_isolated_home)
rm "$home4/.claude/skills/fusion-debug"
if [[ ! -e "$home4/.claude/skills/fusion-debug" ]]; then
    PASS=$((PASS+1)); printf '  PASS: fusion-debug not installed → directory absent\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: fusion-debug should be absent\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

권한:
```bash
chmod +x tests/debug-mode.test.sh
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/debug-mode.test.sh`
Expected: case (1)(2) FAIL because `skills/fusion-debug/` 와 `skills/fusion/prompts/debug-rules.md` 둘 다 없음. (3)(4)는 PASS 가능 (둘 다 absence를 확인). 합계: 약 `2 passed, 2 failed`. exit 1.

(주: Task 1에서 debug-rules.md는 이미 만들어졌으므로 Step 2는 SKILL.md만 누락된 상태에서 실행. (1)(2)는 prompt 합성 자체는 시도되고 결과 prompt 파일이 만들어짐 — render_debug_prompt가 SKILL.md가 아니라 직접 python 호출이라서 — debug-rules.md가 있으면 정상 prompt가 생성됨. 즉 (1)(2) 실은 *Task 1 commit 이후 시점*에는 PASS. (3)(4)도 PASS. 합계 4 passed, 0 failed가 가능.

이 경우 step 2 expected는 "이미 4 passed가 가능하지만 그것은 SKILL.md 부재와 무관 — render_debug_prompt가 인라인이라서". SKILL.md는 *발동 가능성*을 위한 것이지 prompt 합성 자체에는 영향 없음. (4) 케이스가 fusion-debug 디렉토리 부재만 확인해 자명하게 PASS.

따라서 Step 2 expected를 다음으로 수정: "이미 4 passed가 가능 (Task 1에서 debug-rules.md 있고, fusion-debug 부재는 (4)가 자명 PASS). 합계 `4 passed, 0 failed`. 이는 본 task의 핵심이 SKILL.md 자체 존재가 아니라 prompt 합성 검증임을 의미. SKILL.md는 사용자 호출 진입점으로만 필요. Step 3에서 SKILL.md 작성하지만 테스트 결과는 step 2와 같음.")

캡처해서 보고.

- [ ] **Step 3: `skills/fusion-debug/SKILL.md` 작성**

`skills/fusion-debug/SKILL.md` 파일 전체 내용 (정확히 그대로):

````markdown
---
name: fusion-debug
description: Claude↔Codex systematic-debugging 협업. /fusion-debug <symptom>으로 가설→실험→검증→fix 라운드를 핑퐁. Claude=가설·실행·fix, Codex=반증·누락 가설 제안. firmware mode와 직교(둘 다 활성 시 룰셋 모두 적용). 펌웨어 디버깅 단발 작업에 사용.
---

# /fusion-debug — Claude↔Codex systematic-debugging 협업

너(Claude)는 가설을 제안하고 실험·fix를 실행하는 작자(author) 역할을 맡는다. Codex는 read-only 검토자로 매 라운드 가설·실험·fix의 결함과 누락 가설을 지적한다.

## 0. 사전 점검

```bash
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex CLI 미설치"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: git 레포 외부에서는 동작 안 함"; exit 1; }
```

세션 디렉토리:
```bash
FUSION_TS=$(date +%s)
FUSION_RAND=$(printf '%04x' $((RANDOM)))
FUSION_DIR="/tmp/fusion-${FUSION_TS}-${FUSION_RAND}"
mkdir -p "$FUSION_DIR"
echo "fusion state: $FUSION_DIR"
```

스킬 자기 자신 + base resources 위치 확인:
```bash
SKILL_DIR="$HOME/.claude/skills/fusion-debug"
FUSION_BASE_DIR="$HOME/.claude/skills/fusion"
[[ -d "$SKILL_DIR" ]] || { echo "ERROR: /fusion-debug 미설치 — install.sh 재실행"; exit 1; }
[[ -d "$FUSION_BASE_DIR" ]] || { echo "ERROR: /fusion(base) 미설치 — install.sh 재실행"; exit 1; }
[[ -f "$FUSION_BASE_DIR/prompts/debug-rules.md" ]] || { echo "ERROR: debug-rules.md 부재 — Phase 4 install 불완전"; exit 1; }
```

## 1. 입력 파싱

```
/fusion-debug <symptom description>
/fusion-debug --max-rounds N <symptom>   # 옵션, 기본 5
```

```bash
MAX_ROUNDS=5
# --max-rounds N 파싱: 사용자 입력에서 옵션 분리 후 SYMPTOM 변수에 저장
SYMPTOM="<사용자 증상 묘사>"
TASK_TEXT="[debug] symptom: $SYMPTOM — propose hypotheses, design falsifying experiments, optionally apply a fix. Codex (reviewer) will challenge each round."
```

## 2. 작자 라운드 (Claude)

각 라운드에서 다음을 수행:

1. **상황 정리**: 이전 라운드의 가설·실험·결과를 한 줄로 요약
2. **다음 작업 결정** (한 가지):
   - 새 가설 제안 (지금까지 미커버 영역)
   - 기존 가설 검증 실험 설계·실행 (Edit/Bash 도구 사용)
   - 충분히 검증된 가설에 대한 fix 적용
3. **`round-N-claude.txt`에 한 줄 요약 저장**:

```bash
cat > "$FUSION_DIR/round-${round}-claude.txt" <<EOF
hypothesis: <H_n>
experiment: <what was tested and how>
result: <falsified | confirmed | inconclusive>
next action: <next hypothesis or fix>
EOF
```

(라운드별 실제 내용으로 채울 것 — placeholder를 그대로 쓰지 말 것.)

## 3. 검토자 라운드 (Codex)

```bash
round=1   # 매 라운드 start: round=1, 그 후 round=$((round+1))
```

이전 히스토리:
```bash
PREV_HISTORY=""
for ((i=1; i<round; i++)); do
    if [[ -f "$FUSION_DIR/round-${i}-claude.txt" ]]; then
        PREV_HISTORY+="Round ${i} — Claude reply:"$'\n'"$(cat "$FUSION_DIR/round-${i}-claude.txt")"$'\n\n'
    fi
done
[[ -z "$PREV_HISTORY" ]] && PREV_HISTORY="(none)"
```

Prompt 합성 (slot 치환 + debug-rules.md 필수 append + firmware-rules.md 조건부):
```bash
PROMPT_FILE="$FUSION_DIR/round-${round}-prompt.txt"
DIFF_TEXT="$(git diff HEAD)"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"

export TASK_TEXT PREV_HISTORY DIFF_TEXT PROJECT_ROOT FUSION_BASE_DIR PROMPT_FILE
python3 - <<'PYEOF'
import os, json
fusion_base = os.environ["FUSION_BASE_DIR"]
project_root = os.environ.get("PROJECT_ROOT", "")
out_path = os.environ["PROMPT_FILE"]

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

# debug-rules: always append (this is /fusion-debug entry)
with open(debug_path) as f:
    s += "\n\n" + f.read()

# firmware-rules: conditionally append
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
```

Codex 호출:
```bash
LAST_MSG_FILE="$FUSION_DIR/round-${round}-codex.txt"
SECONDS=0
if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2> "$FUSION_DIR/round-${round}-codex.stderr"; then
    sleep 1
    if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2>> "$FUSION_DIR/round-${round}-codex.stderr"; then
        echo "ERROR: codex exec 두 번 모두 실패. stderr는 $FUSION_DIR/round-${round}-codex.stderr"
        exit 1
    fi
fi
ELAPSED=$SECONDS
```

VERDICT 파싱:
```bash
VERDICT=$(bash "$FUSION_BASE_DIR/lib/parse-verdict.sh" < "$LAST_MSG_FILE")
case "$VERDICT" in
    APPROVED)
        echo "== Round $round / $MAX_ROUNDS =="
        echo "Codex review: VERDICT: APPROVED"
        echo "✅ DEBUG COMPLETE in $round rounds — root cause + fix 합의 (state: $FUSION_DIR)"
        printf 'APPROVED in round %d\n' "$round" > "$FUSION_DIR/final.txt"
        exit 0
        ;;
    REVISE)
        # Severity counts (Phase 2/3 호환 regex)
        BLOCKERS=$(grep -cE '^[[:space:]]*[-*]?[[:space:]]*BLOCKER([[:space:]]+\(|:)' "$LAST_MSG_FILE" 2>/dev/null); BLOCKERS=${BLOCKERS:-0}
        MAJORS=$(grep -cE   '^[[:space:]]*[-*]?[[:space:]]*MAJOR([[:space:]]+\(|:)'   "$LAST_MSG_FILE" 2>/dev/null); MAJORS=${MAJORS:-0}
        MINORS=$(grep -cE   '^[[:space:]]*[-*]?[[:space:]]*MINOR([[:space:]]+\(|:)'   "$LAST_MSG_FILE" 2>/dev/null); MINORS=${MINORS:-0}
        echo "== Round $round / $MAX_ROUNDS =="
        echo "Codex review: VERDICT: REVISE — ${BLOCKERS} BLOCKER, ${MAJORS} MAJOR, ${MINORS} MINOR"
        ;;
    *)
        echo "ERROR: VERDICT 마커 누락 — 프롬프트 실패 가능성. state: $LAST_MSG_FILE"
        exit 1
        ;;
esac
```

다음 라운드:
```bash
round=$((round + 1))
if (( round > MAX_ROUNDS )); then
    # §4 MAX_ROUNDS 처리로 진행
    :
else
    # §3 처음으로 돌아간다
    :
fi
```

## 4. MAX_ROUNDS 도달

```bash
echo "⚠️ DEBUG INCONCLUSIVE — $MAX_ROUNDS rounds"
echo "미해결 가설은 $LAST_MSG_FILE 참조"
echo "state: $FUSION_DIR"
printf 'INCONCLUSIVE at %d\n' "$MAX_ROUNDS" > "$FUSION_DIR/final.txt"
exit 1
```

## 5. Red Flags

- ❌ Codex 반증을 무조건 적용 — 명백히 잘못된 지적은 거부, 이유 round-N-claude.txt에 기록
- ❌ 가설 검증 없이 fix 적용 — 가설 → 실험 → 결과 → fix 순서 유지
- ❌ "맞을 것 같다"식 confirmation bias — 실험은 항상 falsifying 방향
- ❌ VERDICT 마커 없을 때 자체 판단 — 즉시 명시적 에러
- ❌ `--sandbox read-only` 풀기 — Codex는 코드 수정 안 함

## 6. 성공·실패 신호

| 결과 | exit | 표시 |
|---|---|---|
| APPROVED 도달 | 0 | `✅ DEBUG COMPLETE in N rounds — root cause + fix 합의` |
| MAX_ROUNDS 도달 | 1 | `⚠️ DEBUG INCONCLUSIVE — N rounds, 미해결 가설은 ...` |
| codex 미설치, git 외부 | 1 | `ERROR: ...` |
| VERDICT 마커 누락 | 1 | `ERROR: VERDICT 마커 누락` |
| codex exec 2회 실패 | 1 | `ERROR: codex exec 두 번 모두 실패` |
| /fusion-debug 또는 base 미설치 | 1 | `ERROR: ... — install.sh 재실행` |
````

- [ ] **Step 4: 통과 확인**

Run: `bash tests/debug-mode.test.sh`
Expected: 모든 4 케이스 PASS. 합계 `4 passed, 0 failed`. exit 0.

회귀:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
bash tests/parse-verdict.test.sh
bash tests/auto-review-hook.test.sh
bash tests/settings-merge.test.sh
bash tests/firmware-mode.test.sh
```
Expected: 모두 exit 0; 13+14+15+4 = 46 PASS. 총 50.

- [ ] **Step 5: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add skills/fusion-debug/SKILL.md tests/debug-mode.test.sh
git commit -m "feat: /fusion-debug 슬래시 스킬 + 4 케이스 검증

systematic-debugging 협업 진입점. Claude=가설·실행·fix, Codex=
반증·누락 가설 제안. base reviewer.md + debug-rules.md 필수
append + firmware-rules.md 조건부(fusion.firmware=true). MAX_ROUNDS
기본 5. parse-verdict.sh 그대로 재사용, severity regex Phase 2/3
호환. tests/debug-mode.test.sh로 4 케이스 검증 (firmware off/on,
debug-rules 부재, fusion-debug 부재)."
```

---

### Task 3: `install.sh`에 `fusion-debug` 심볼릭 링크 추가

**Files:**
- Modify: `install.sh`

기존 `install.sh`는 `~/.claude/skills/fusion`만 만든다. Phase 4는 `~/.claude/skills/fusion-debug`도 만들어야 한다. 멱등 + 기존 link 보존.

- [ ] **Step 1: install.sh 현 위치 확인**

Run:
```bash
grep -n 'SRC=' /Users/jekim/01.Projects/11.CodexClaudeFusion/install.sh
grep -n 'fusion-debug' /Users/jekim/01.Projects/11.CodexClaudeFusion/install.sh
```
Expected: SRC 라인 1줄, fusion-debug 라인 0줄 (아직 미추가).

- [ ] **Step 2: install.sh 수정**

기존 install.sh의 핵심 부분을 함수로 추출하고 두 번 호출. 다음 정확한 블록을 찾기:

```bash
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

다음으로 교체:

```bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_PARENT="$HOME/.claude/skills"
mkdir -p "$DEST_PARENT"

# Idempotent symlink installer for one skill name.
install_skill() {
    local name="$1"
    local src="$REPO_DIR/skills/$name"
    local dest="$DEST_PARENT/$name"

    if [[ ! -d "$src" ]]; then
        echo "ERROR: source not found: $src" >&2
        exit 1
    fi

    if [[ -L "$dest" ]]; then
        local current
        current="$(readlink "$dest")"
        if [[ "$current" == "$src" ]]; then
            echo "OK: $dest already points to $src (no change)"
            return 0
        fi
        echo "REPLACING symlink: $dest"
        echo "  was -> $current"
        echo "  now -> $src"
        rm "$dest"
    elif [[ -e "$dest" ]]; then
        echo "ERROR: $dest exists but is not a symlink. Refusing to overwrite." >&2
        echo "       Move or remove it manually, then re-run." >&2
        exit 1
    fi

    ln -s "$src" "$dest"
    echo "INSTALLED: $dest -> $src"
}

install_skill "fusion"
install_skill "fusion-debug"
echo "이제 Claude Code에서 /fusion (review) 와 /fusion-debug (systematic-debugging) 모두 사용 가능합니다."
```

- [ ] **Step 3: 검증**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
bash -n install.sh && echo "syntax OK"
grep -c 'install_skill ' install.sh
```
Expected: `syntax OK`, install_skill 호출 ≥ 2회 (fusion, fusion-debug).

실제 실행은 사용자에게 맡김 (환경 변경). 단 dry-run 검증:
```bash
bash -c 'set -e; bash install.sh && ls -la ~/.claude/skills/fusion ~/.claude/skills/fusion-debug 2>/dev/null'
```
Expected: 두 심볼릭 링크 모두 정상 작동.

- [ ] **Step 4: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add install.sh
git commit -m "feat: install.sh에 fusion-debug 심볼릭 링크 추가

기존 fusion 링크 + 새 fusion-debug 링크 모두 멱등 관리. install_skill
helper 함수로 추출해 두 번 호출. 두 링크 모두 ~/.claude/skills/
아래에 만들어 Claude Code에서 /fusion (review) + /fusion-debug
(systematic-debugging) 모두 사용 가능."
```

---

### Task 4: README "디버깅 모드 (Phase 4)" 섹션 추가

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 기존 위치 확인**

Run:
```bash
grep -n '^## 후속 단계 로드맵' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
```
Expected: 한 줄.

- [ ] **Step 2: 새 섹션 삽입**

`README.md`의 `## 후속 단계 로드맵` 라인 직전에 다음 새 섹션 정확히 그대로 삽입:

```
## 디버깅 모드 (Phase 4)

ARM 펌웨어나 일반 코드의 *디버깅* 작업을 systematic-debugging 워크플로(가설→실험→검증→fix)로 진행합니다. Phase 1의 review 핑퐁과 별개의 진입점 `/fusion-debug`로, 작자(Claude)가 가설·실험·fix를 적용하고 검토자(Codex)가 매 라운드 반증과 누락 가설을 제시합니다.

### 사용법

```bash
/fusion-debug <symptom description>
/fusion-debug --max-rounds N <symptom>   # 기본 5
```

예시:
```
/fusion-debug athens-gate-fw에서 시리얼 출력이 약 5분마다 한 줄씩 깨짐
```

라운드별로 Claude는 가설·실험·fix를 진행하고, Codex는 결함과 누락 가설을 지적합니다. 합의 도달 시:
```
✅ DEBUG COMPLETE in 3 rounds — root cause + fix 합의 (state: /tmp/fusion-...)
```

MAX_ROUNDS 도달 시:
```
⚠️ DEBUG INCONCLUSIVE — 5 rounds, 미해결 가설은 ...
```

### 룰셋 (3축)

- **A. Hypothesis quality** — 가설이 구체적이고 falsifying 실험으로 검증됐는지, 누락 가설은 없는지
- **B. Experiment rigor** — 실험이 falsify 지향이고 최소 변수만 다루는지
- **C. Fix correctness** — fix가 root cause를 다루는지, silent failure나 regression이 없는지

심각도 매핑은 Phase 1과 동일 (BLOCKER/MAJOR/MINOR). 펌웨어 모드(`fusion.firmware: true`)와 직교 — 둘 다 활성 시 양쪽 룰셋 모두 적용되며 펌웨어 이슈는 `(A.ISR)`/`(B.VOL)` prefix로 식별.

### 검증 시나리오 (dogfooding)

| 시나리오 | 기대 결과 | 결과 |
|---|---|---|
| D1: 단순 1라운드 가설 검증 (알려진 off-by-one) | 1라운드 APPROVED | (추후 기록) |
| D2: 다중 라운드 가설 후보 (3~4) | 3~4라운드 APPROVED | (추후 기록) |
| D3: MAX_ROUNDS 도달 (모호한 증상) | INCONCLUSIVE | (추후 기록) |
| D4: firmware mode + debug 동시 활성 | `(A.ISR)` 또는 `(B.VOL)` prefix + debug 룰셋 결과 | (추후 기록) |

```

또한 후속 단계 로드맵의 Phase 4 라인 갱신:

찾기:
```
- **Phase 4**: systematic-debugging / TDD 통합
```

교체:
```
- **Phase 4**: systematic-debugging 협업 ✅ 구현 진행 중 (`/fusion-debug` MVP — 위 "디버깅 모드" 섹션 참조; TDD는 Phase 4.x)
```

- [ ] **Step 3: 검증**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
grep -c '^## 디버깅 모드' README.md
grep -c '^| D[1-4]:' README.md
grep -c 'fusion-debug' README.md
grep -c '구현 진행 중' README.md
```
Expected: 각 1, 4, ≥1, ≥1.

- [ ] **Step 4: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add README.md
git commit -m "docs: README에 디버깅 모드 섹션 추가 + 로드맵 갱신

Phase 4 systematic-debugging 협업 사용자 가이드. /fusion-debug
사용법, 출력 형식 (✅ DEBUG COMPLETE / ⚠️ DEBUG INCONCLUSIVE),
3축 룰셋(가설·실험·fix), firmware mode 직교 동작 안내, D1~D4
dogfooding 시나리오 표 (결과는 추후 기록). 후속 단계 로드맵의
Phase 4 라인을 \"구현 진행 중\"으로 갱신."
```

---

### Task 5: 통합 정적 검증

산출물 없음, 커밋 없음.

- [ ] **Step 1: bash 문법 검사**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
bash -n skills/fusion/lib/auto-review-hook.sh \
 && bash -n skills/fusion/lib/parse-verdict.sh \
 && bash -n install.sh \
 && bash -n enable-auto.sh && bash -n disable-auto.sh \
 && bash -n enable-firmware.sh && bash -n disable-firmware.sh \
 && bash -n tests/parse-verdict.test.sh \
 && bash -n tests/auto-review-hook.test.sh \
 && bash -n tests/settings-merge.test.sh \
 && bash -n tests/firmware-mode.test.sh \
 && bash -n tests/debug-mode.test.sh \
 && echo "all syntax OK"
```
Expected: `all syntax OK`

- [ ] **Step 2: 모든 테스트 sweep**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
echo "=== parse-verdict ==="; bash tests/parse-verdict.test.sh; echo "exit=$?"
echo "=== auto-review-hook ==="; bash tests/auto-review-hook.test.sh; echo "exit=$?"
echo "=== settings-merge ==="; bash tests/settings-merge.test.sh; echo "exit=$?"
echo "=== firmware-mode ==="; bash tests/firmware-mode.test.sh; echo "exit=$?"
echo "=== debug-mode ==="; bash tests/debug-mode.test.sh; echo "exit=$?"
```
Expected: 13 + 14 + 15 + 4 + 4 = 50 PASS, 모두 exit 0.

- [ ] **Step 3: slot 토큰·base resources 정합성**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
echo "--- reviewer.md slots ---"
grep -o '{{[A-Z_]\+}}' skills/fusion/prompts/reviewer.md | sort -u
echo "--- fusion-debug/SKILL.md slots ---"
grep -o '{{[A-Z_]\+}}' skills/fusion-debug/SKILL.md | sort -u
echo "--- debug-rules.md slots (must be empty) ---"
grep -o '{{[A-Z_]\+}}' skills/fusion/prompts/debug-rules.md | sort -u
```
Expected: 처음 2개 동일 3 토큰, debug-rules.md는 빈 출력.

- [ ] **Step 4: Phase 1·2·3 무손**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git diff 49b8e54 -- \
  skills/fusion/SKILL.md \
  skills/fusion/lib/auto-review-hook.sh \
  skills/fusion/lib/parse-verdict.sh \
  skills/fusion/prompts/reviewer.md \
  skills/fusion/prompts/firmware-rules.md \
  enable-auto.sh disable-auto.sh \
  enable-firmware.sh disable-firmware.sh
```
Expected: 빈 출력 (Phase 1·2·3 산출물 모두 무변경).

- [ ] **Step 5: install.sh 멱등 dry-run**

```bash
bash -n /Users/jekim/01.Projects/11.CodexClaudeFusion/install.sh && echo "syntax OK"
```
Expected: `syntax OK`. (실제 install 실행은 사용자가 결정.)

- [ ] **Step 6: 변경 없음**

```bash
git status --short
```
Expected: 빈 출력.

산출물·커밋 없음.

---

### Task 6: dogfooding D1~D4 (사용자 환경 자동 시뮬레이션)

Phase 1·2·3과 동일 패턴 — 임시 git 레포에서 자동 시뮬레이션. 결과를 README에 기록 + 커밋.

- [ ] **Step 1: install.sh 실행 (fusion-debug 심볼릭 링크 활성화)**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
./install.sh
ls -la ~/.claude/skills/fusion ~/.claude/skills/fusion-debug
```
Expected: 두 심볼릭 링크 모두 정상.

- [ ] **Step 2: 임시 디버깅 레포 셋업**

```bash
cd /tmp
rm -rf p4-dogfood
mkdir p4-dogfood && cd p4-dogfood
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
```

- [ ] **Step 3: D1 — 단순 가설 검증 시뮬레이션**

`/fusion-debug` 자체는 슬래시 스킬이라 Claude session에서만 직접 호출 가능. 자동 시뮬레이션은 SKILL.md의 *prompt 합성 + Codex 호출 + VERDICT 파싱* 흐름을 인라인으로 실행.

```bash
cd /tmp/p4-dogfood
cat > buggy.c <<'EOF'
int sum(int *arr, int n) {
    int s = 0;
    for (int i = 0; i <= n; i++) s += arr[i];   /* HYPOTHESIS H1: off-by-one */
    return s;
}
EOF
git add -N buggy.c

FUSION_TS=$(date +%s)
FUSION_RAND=$(printf '%04x' $((RANDOM)))
FUSION_DIR="/tmp/fusion-${FUSION_TS}-${FUSION_RAND}"
mkdir -p "$FUSION_DIR"

SKILL_DIR="$HOME/.claude/skills/fusion-debug"
FUSION_BASE_DIR="$HOME/.claude/skills/fusion"

PROMPT_FILE="$FUSION_DIR/round-1-prompt.txt"
LAST_MSG_FILE="$FUSION_DIR/round-1-codex.txt"
DIFF_TEXT="$(git diff HEAD)"
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
TASK_TEXT="[debug] symptom: sum returns wrong total — propose hypotheses, design falsifying experiments, optionally apply a fix. Codex (reviewer) will challenge each round."
PREV_HISTORY="(none)"

export TASK_TEXT PREV_HISTORY DIFF_TEXT PROJECT_ROOT FUSION_BASE_DIR PROMPT_FILE
python3 - <<'PYEOF'
import os, json
fusion_base = os.environ["FUSION_BASE_DIR"]
project_root = os.environ.get("PROJECT_ROOT", "")
out_path = os.environ["PROMPT_FILE"]
reviewer_path = os.path.join(fusion_base, "prompts", "reviewer.md")
debug_path = os.path.join(fusion_base, "prompts", "debug-rules.md")
firmware_path = os.path.join(fusion_base, "prompts", "firmware-rules.md")
with open(reviewer_path) as f: s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])
with open(debug_path) as f: s += "\n\n" + f.read()
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
    with open(firmware_path) as f: s += "\n\n" + f.read()
with open(out_path, "w") as f: f.write(s)
PYEOF

SECONDS=0
codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2> "$FUSION_DIR/round-1-codex.stderr"
echo "rc=$?, ${SECONDS}s, state=$FUSION_DIR"
echo "--- Codex output ---"
cat "$LAST_MSG_FILE"
```
Expected: Codex가 off-by-one 가설을 검증하거나 추가 가설 제시 (BLOCKER/MAJOR). 결과 캡처.

- [ ] **Step 4: D2 — 다중 라운드 시뮬레이션 (Claude가 fix 시도 후 round 2 실행)**

D1 결과를 보고 Claude(이 task 실행자)가 buggy.c 수정 (`i < n`) + `round-1-claude.txt` 작성. 그 다음 round=2로 prompt 다시 합성하고 codex 호출. APPROVED 도달 기대.

(Step 3 코드와 거의 동일하지만 round=2, PREV_HISTORY는 round-1-claude.txt 내용.)

이 단계는 Claude session에서 사용자 안내 + 직접 진행. 결과 기록.

- [ ] **Step 5: D3 — MAX_ROUNDS 도달 시뮬레이션**

`--max-rounds 2` + 양립 불가 증상으로 짧게 인쇄.
실제 hook 실행이 아닌 INCONCLUSIVE 분기 표시 검증.

- [ ] **Step 6: D4 — firmware + debug 결합**

`enable-firmware.sh` 실행 후 D1과 같은 흐름. prompt에 DEBUGGING + FIRMWARE 섹션 둘 다 등장 + Codex 출력에 `(A.ISR)` 또는 `(B.VOL)` prefix 가능성.

- [ ] **Step 7: README의 D1~D4 결과 표 갱신**

실제 결과로 "(추후 기록)" 자리를 채움.

- [ ] **Step 8: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add README.md
git commit -m "docs: Phase 4 dogfooding D1~D4 결과 기록 (인수 통과)

systematic-debugging 협업 모드 실전 검증. D1(단순 가설), D2(다중
라운드), D3(MAX_ROUNDS), D4(firmware+debug) 결과를 README 시나리오
표에 채움. Phase 4 인수 기준 충족."
```

- [ ] **Step 9: 정리**

```bash
rm -rf /tmp/p4-dogfood
```

---

## Self-Review 체크리스트

- [ ] 스펙 §1~§11 각 절이 적어도 한 task로 다뤄졌는가
- [ ] base reviewer.md, parse-verdict.sh, fusion/SKILL.md, auto-review-hook.sh, firmware-rules.md, enable/disable-*.sh 모두 무변경 (Phase 1·2·3 회귀 0)
- [ ] fusion-debug/SKILL.md의 python 합성 코드가 tests/debug-mode.test.sh의 render_debug_prompt와 의미상 동일 (둘 다 base + debug + 조건부 firmware)
- [ ] severity regex가 Phase 2/3와 동일 (`BLOCKER([[:space:]]+\(|:)` 등)
- [ ] install.sh가 fusion + fusion-debug 두 링크 모두 멱등 관리
- [ ] 50 tests sweep PASS (parse-verdict 13 + auto-review-hook 14 + settings-merge 15 + firmware-mode 4 + debug-mode 4)

---

**Plan 완료.** 저장 위치: `docs/superpowers/plans/2026-05-09-codex-claude-fusion-phase4.md`
