# Codex–Claude Fusion (Phase 4) 설계 스펙

- **작성일**: 2026-05-09
- **상태**: Draft → 사용자 위임 진행
- **범위**: Phase 4 systematic-debugging 협업 모드 MVP (TDD는 Phase 4.x)
- **Phase 1·2·3 의존성**: master 시점 (40+ 커밋, 46 tests PASS, A1~A5 + F1~F4 dogfooding 통과)

## 1. 동기

Phase 1~3은 코드 *리뷰* 협업에 강하다. 그러나 사용자의 주 사용 패턴 — 펌웨어 디버깅 단발 작업 — 에서는 "어디가 잘못됐는지 추적" 자체가 핵심이고, 단순 리뷰 단위로는 효율이 낮다. Phase 4는 superpowers의 systematic-debugging 워크플로(가설→실험→검증→fix)를 Claude↔Codex 협업으로 가속한다.

핵심 원칙:
- **새 슬래시 진입점 `/fusion-debug`**: Phase 1 `/fusion`은 무변경 — 회귀 위험 0
- **Phase 1 인프라 최대 재사용**: `parse-verdict.sh`, base `reviewer.md`, severity 분류, VERDICT 마커 그대로
- **별도 `debug-rules.md` 룰셋**: Phase 3 firmware-rules.md와 같은 append 패턴
- **역할 분담**: Claude=가설·실행·fix, Codex=반증·누락 가설 제안 (Phase 1 author/reviewer 패턴 일관)

## 2. 범위와 비범위

### Phase 4에 포함
- 신규 슬래시 스킬 `/fusion-debug` (`skills/fusion-debug/SKILL.md`)
- 신규 룰셋 `skills/fusion/prompts/debug-rules.md` (~40~50줄)
- Phase 1 인프라 재사용: `parse-verdict.sh`, `reviewer.md`, severity grep, VERDICT 마커
- Phase 3 firmware mode와 호환: 양쪽 활성 시 base + debug-rules + firmware-rules 모두 append
- 단위 테스트 `tests/debug-mode.test.sh` (4 케이스)
- README "디버깅 모드 (Phase 4)" 섹션
- `install.sh` 보강: `~/.claude/skills/fusion-debug` 심볼릭 링크 추가

### Phase 4 비범위 (Phase 4.x)
- TDD 모드 (`/fusion-tdd`)
- 가설 트리 시각화·세션 재개
- 라운드 수 사용자 정의 옵션
- Codex의 자동 실험 실행 (sandbox 풀기 — 안전상 unfeasible)

### 명시적 비목표
- Phase 1 SKILL.md 변경 (회귀 위험 회피)
- parse-verdict.sh, reviewer.md 변경
- 새 VERDICT 종류 추가 (APPROVED/REVISE 그대로 의미 재해석)

## 3. 아키텍처 결정 요약

| 항목 | 결정 | 이유 |
|---|---|---|
| 진입점 | 새 슬래시 `/fusion-debug` | 명시적, Phase 1 무변경 |
| 워크플로 | systematic-debugging만 | 사용자 우선순위, TDD는 후속 |
| 역할 | Claude=가설·실행·fix, Codex=반증 | Phase 1 author/reviewer 패턴 일관 |
| 룰 통합 | base reviewer.md + debug-rules.md append | Phase 3 패턴 재사용, 무변경 원칙 |
| MAX_ROUNDS | 기본 5 (Phase 1의 3보다 큼) | 디버깅은 가설 검증 라운드 더 필요 |
| VERDICT 의미 | APPROVED="root cause 확정 + fix 적용", REVISE="더 가설 탐색 필요" | parse-verdict.sh 무변경, prompt에서 의미 재정의 |
| firmware 호환 | base + debug-rules + firmware-rules 모두 append (둘 다 활성 시) | 직교 룰셋 합성 |

## 4. 파일 레이아웃

```
CodexClaudeFusion/
├── skills/
│   ├── fusion/                        # Phase 1·2·3 (무변경)
│   │   ├── SKILL.md                   # /fusion (review 모드)
│   │   ├── prompts/
│   │   │   ├── reviewer.md            # base
│   │   │   ├── firmware-rules.md      # Phase 3
│   │   │   └── debug-rules.md         # NEW: Phase 4
│   │   └── lib/
│   │       └── parse-verdict.sh       # Phase 1 (무변경)
│   └── fusion-debug/                   # NEW
│       └── SKILL.md                    # NEW: /fusion-debug 진입점
├── tests/
│   └── debug-mode.test.sh              # NEW: 4 케이스
├── install.sh                          # 변경: fusion-debug 심볼릭 링크 추가
├── README.md                           # "디버깅 모드 (Phase 4)" 섹션 추가
└── docs/superpowers/specs/2026-05-09-codex-claude-fusion-phase4-design.md
```

### 무변경 (Phase 1·2·3)
- `skills/fusion/SKILL.md`, `reviewer.md`, `parse-verdict.sh`, `firmware-rules.md`
- `auto-review-hook.sh`, `enable-auto.sh`, `disable-auto.sh`
- `enable-firmware.sh`, `disable-firmware.sh`

### 의존성
Phase 1~3과 동일. 추가 없음.

## 5. `debug-rules.md` 본체

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

### 디테일
- 슬롯 토큰 사용 금지 (slot 치환 후 append).
- BLOCKER/MAJOR/MINOR 분류는 base reviewer.md와 동일 인프라 (severity grep regex 호환).
- firmware mode와 직교 — 둘 다 활성 시 prompt 끝에 두 룰셋 모두 등장.

## 6. `skills/fusion-debug/SKILL.md` 구조

Phase 1 SKILL.md와 거의 동일한 구조이나 다음 차이:

### 사전 점검 (§0)
Phase 1과 동일.

### 입력 파싱 (§1)
```
사용자 호출: /fusion-debug <symptom description>

MODE는 사실상 항상 "task" (사용자가 증상 묘사로 시작).
TASK_TEXT="[debug] symptom: <symptom> — propose hypotheses, design
falsifying experiments, optionally apply a fix. Codex (reviewer) will
challenge each round."

MAX_ROUNDS=5 (Phase 1 default 3보다 큼; --max-rounds N으로 override 가능)
```

### 작자 라운드 (§2)
Claude가 매 라운드 다음을 수행:
1. 현재까지의 가설·실험 결과 정리
2. 다음 작업 선택: 새 가설 / 실험 / fix
3. Edit/Bash 도구로 적용
4. `round-N-claude.txt`에 한 줄 요약:
   ```
   hypothesis: <one-line H_n>
   experiment: <what was tested and how>
   result: <outcome — falsified / confirmed / inconclusive>
   next action: <next hypothesis or fix>
   ```

### Base resources 위치

새 SKILL.md(`fusion-debug`)는 `$HOME/.claude/skills/fusion-debug/`에 설치되지만, base resources(`reviewer.md`, `parse-verdict.sh`, `debug-rules.md`, `firmware-rules.md`)는 모두 Phase 1 디렉토리 `$HOME/.claude/skills/fusion/`에 위치. SKILL.md가 다음 변수로 참조:

```bash
SKILL_DIR="$HOME/.claude/skills/fusion-debug"   # 자기 자신 (사전 점검용)
FUSION_BASE_DIR="$HOME/.claude/skills/fusion"   # base resources
```

Prompt 합성 시 `$FUSION_BASE_DIR/prompts/reviewer.md` (base) + `$FUSION_BASE_DIR/prompts/debug-rules.md` (필수) + 조건부 `$FUSION_BASE_DIR/prompts/firmware-rules.md`를 append. parse-verdict 호출도 `$FUSION_BASE_DIR/lib/parse-verdict.sh`.

### 검토자 라운드 (§3) — Codex
prompt 합성 (python heredoc, Phase 1과 동일 패턴):
- base = `reviewer.md`
- slot 치환
- **항상**: `+= debug-rules.md` (fusion-debug 진입점이라 필수)
- **조건부**: `fusion.firmware: true`이면 `+= firmware-rules.md` (Phase 3 호환)

코덱스 호출은 Phase 1과 동일 (`codex exec --sandbox read-only -o ... - <`).

VERDICT 파싱은 Phase 1 `parse-verdict.sh` 그대로 재사용.

### 결과 출력 (§6)
- APPROVED → `✅ DEBUG COMPLETE in N rounds — root cause + fix 합의 (state: ...)`
- MAX_ROUNDS 도달 → `⚠️ DEBUG INCONCLUSIVE — N rounds, 미해결 가설은 round-N-codex.txt 참조 (state: ...)`
- VERDICT 마커 누락 → `ERROR: VERDICT 마커 누락 — 프롬프트 실패 가능성. state: ...`

severity 카운트 출력은 Phase 2 hook과 동일 (BLOCKER/MAJOR/MINOR 카운트). debug 모드에서도 사용자가 한 줄로 진행 상황 파악.

## 7. install.sh 보강

기존 `~/.claude/skills/fusion → 본 레포/skills/fusion`에 추가하여 `~/.claude/skills/fusion-debug → 본 레포/skills/fusion-debug` 링크. 멱등 (이미 올바른 링크면 noop).

## 8. 에러 처리 / 엣지 케이스

| 케이스 | 처리 |
|---|---|
| codex/git CLI 부재 | Phase 1 동일 (silent exit on hook; 명시 에러 on 수동 호출) |
| `~/.claude/skills/fusion-debug` 미설치 | 명시적 에러 (사용자가 install.sh 재실행) |
| `debug-rules.md` 부재 | 명시적 에러 (debug 모드는 룰셋 필수) |
| MAX_ROUNDS 도달 | "DEBUG INCONCLUSIVE" 안내 + state 경로 |
| firmware mode + debug 동시 활성 | base + debug-rules + firmware-rules 모두 append |
| settings.json 손상 | base + debug-rules만 (firmware 검사 silent fallback) |

## 9. 검증 전략

### 자동 단위 테스트 — `tests/debug-mode.test.sh`

| 케이스 | 기대 |
|---|---|
| (1) 정상 prompt 합성: base + debug-rules.md | prompt에 `DEBUGGING-MODE REVIEW RULES` 등장 |
| (2) firmware mode 동시 활성 | prompt에 `DEBUGGING-MODE` + `FIRMWARE-SPECIFIC` 둘 다 등장 |
| (3) `debug-rules.md` 부재 | 명시적 에러 + exit 1 |
| (4) `~/.claude/skills/fusion-debug` 미설치 | 명시적 에러 + exit 1 |

테스트는 SKILL.md의 prompt 합성 단계를 직접 시뮬레이션하거나 (가능하면) `bash` invocation으로 SKILL.md 안의 코드 블록을 실행해 prompt 파일 검사. Phase 3 firmware-mode.test.sh와 같은 패턴.

### 시나리오 dogfooding

| 시나리오 | 기대 |
|---|---|
| D1: 단순 1라운드 가설 검증 (예: 알려진 off-by-one) | 1라운드 APPROVED |
| D2: 다중 라운드 가설 후보 (3~4 라운드) | round 1~3에서 가설 좁히고 round 4 APPROVED |
| D3: MAX_ROUNDS 도달 (양립 불가 또는 너무 모호한 증상) | DEBUG INCONCLUSIVE |
| D4: firmware mode + debug 동시 활성 (예: ISR race 의심) | 출력에 `(A.ISR)` 또는 `(B.VOL)` prefix + debug-rules 적용 결과 |

### Phase 4 인수 기준

`athens-gate-fw` 또는 `GateReader`의 실제 디버그 작업 1건에 `/fusion-debug` 적용해 root cause 추적 또는 inconclusive 결과 + 사용자 만족도 확인.

## 10. 후속 단계 로드맵 (참고)

| 항목 | 내용 | Phase 4 의존성 |
|---|---|---|
| Phase 4.x | TDD 모드 (`/fusion-tdd`) — Codex가 실패 테스트 제안, Claude 구현 | 새 SKILL.md + tdd-rules.md (debug-rules.md 패턴 재사용) |
| Phase 4.x | 가설 트리 시각화·세션 재개 (state 디렉토리 풍성화) | round-N-claude.txt 형식 확장 |
| Phase 5+ | 다중 AI 협업 (Claude+Codex+Gemini) | 룰셋·합의 메커니즘 일반화 |

## 11. 결정 사항 트레이스 (이번 브레인스토밍 확정)

1. 워크플로: systematic-debugging만 (TDD는 Phase 4.x)
2. 진입점: 새 슬래시 `/fusion-debug` (Phase 1 `/fusion` 무변경)
3. 역할 분담: Claude=가설·실행·fix, Codex=반증·누락 가설 제안 (Phase 1 패턴)
4. 룰 통합: base reviewer.md + debug-rules.md append (Phase 3 패턴)
5. VERDICT: 기존 APPROVED/REVISE 의미 재해석
6. MAX_ROUNDS: 기본 5 (Phase 1의 3보다 큼)
7. firmware mode 호환: 직교, 둘 다 활성 시 룰셋 모두 적용
