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
