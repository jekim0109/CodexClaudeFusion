---
name: fusion-debug
description: Claude↔Codex systematic-debugging 협업. /fusion-debug <symptom>으로 가설→실험→검증→fix 라운드를 핑퐁. Claude=가설·실행·fix, Codex=반증·누락 가설 제안. firmware mode와 직교(둘 다 활성 시 룰셋 모두 적용). 펌웨어 디버깅 단발 작업에 사용.
---

# /fusion-debug — Claude↔Codex systematic-debugging 협업

너(Claude)는 가설을 제안하고 실험·fix를 실행하는 작자(author) 역할을 맡는다. Codex는 read-only 검토자로 매 라운드 가설·실험·fix의 결함과 누락 가설을 지적한다.

## 글로벌 House Rules 반영

이 스킬은 사용자의 전역 코딩 지침을 따른다. 특히:

- 디버깅 시작 전에 관찰된 증상, 가정, 성공 기준, 불확실한 해석을 명시한다.
- 가설은 원인-결과가 구체적이어야 하고, 실험은 가능한 한 한 변수를 반증하도록 설계한다.
- 충분히 검증되지 않은 상태에서 fix를 적용하지 않는다.
- 최소 변경을 우선한다. 증상과 무관한 리팩터링, 새 기능, 방어적 침묵 처리는 하지 않는다.
- 완료 주장 전 관련 테스트/빌드/로그/grep 등 검증 출력을 확인한다.
- 위험·비가역 동작(삭제, force push, 히스토리 재작성, 안전장치 우회, 파괴적 DB 작업, 외부 발신/deploy, `sudo`, 프로젝트 범위 밖 쓰기)은 사용자 명시 승인 없이 실행하지 않는다.
- Codex 반증은 검토 후 수용/기각한다. 잘못된 지적은 적용하지 말고 이유를 기록한다.

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
3. **검증**: 실행한 실험·테스트·로그 확인의 핵심 출력과 exit code를 확인
4. **`round-N-claude.txt`에 한 줄 요약 저장**:

```bash
cat > "$FUSION_DIR/round-${round}-claude.txt" <<EOF
hypothesis: <H_n>
experiment: <what was tested and how>
result: <falsified | confirmed | inconclusive>
verification: <command or evidence checked>
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
