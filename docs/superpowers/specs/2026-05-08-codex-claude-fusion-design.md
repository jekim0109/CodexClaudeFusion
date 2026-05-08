# Codex–Claude Fusion (Phase 1) 설계 스펙

- **작성일**: 2026-05-08
- **상태**: Draft → 사용자 리뷰 대기
- **범위**: Phase 1 핑퐁 엔진 MVP (Phase 2~4는 후속)

## 1. 동기

Claude로 작성한 코드를 Codex가 검증하고, 그 반대도 수행할 때 코드 품질이 눈에 띄게 향상된다는 것을 사용자가 수동 운용으로 확인했다. 본 스펙은 이 상호 검증 루프를 **수동 트리거 1회로 자동 핑퐁**까지 진행하도록 자동화하는 슬래시 스킬 `/fusion`을 정의한다.

주 사용 환경은 펌웨어 디버깅·실험 단발 작업(예: `athens-gate-fw`, `GateReader`)이며, superpowers의 `systematic-debugging` / `test-driven-development` 워크플로 정신을 참고한다.

## 2. 범위와 비범위

### Phase 1에 포함
- 슬래시 스킬 `/fusion` (두 모드: task 모드, diff 모드)
- 작자=Claude, 검토자=Codex 고정 역할의 자동 핑퐁 루프
- VERDICT 마커 기반 합의 감지 + 최대 라운드 안전망
- 라운드별 상태를 임시 디렉토리에 기록 (사후 검토용)
- `codex` CLI 직접 호출 (`codex exec --sandbox read-only`)

### Phase 1 비범위 (별도 단계)
- **Phase 2**: `PostToolUse` hook 기반 자동 트리거
- **Phase 3**: 펌웨어 특화 검증 룰셋 (ARM/embedded, ISR, watchdog 등)
- **Phase 4**: `systematic-debugging` / TDD 통합 (가설/반증을 양 AI가 분담)

### 명시적 비목표
- 자동 재시도 정책 정교화 (지수 백오프 등)
- 대형 diff 자동 분할·요약
- Codex 직접 코드 수정 (Phase 1에서 Codex는 read-only 리뷰만)

## 3. 아키텍처 결정 요약

| 항목 | 결정 | 이유 |
|---|---|---|
| 오케스트레이션 위치 | 현재 Claude Code 세션 내부 (인-세션) | 단발 작업에 가벼움, 기존 도구(Edit/Bash) 재사용 |
| Codex 호출 방식 | `codex exec --sandbox read-only` 직접 호출 | 프롬프트·모드 자유 제어, 인증은 codex CLI 위임 |
| 종료 조건 | 합의 감지 + 최대 N라운드 (기본 3) | 일반 케이스는 합의로, 비정상은 안전망으로 |
| 역할 분담 | 작자=Claude, 검토자=Codex 고정 | 현재 세션 작자 활용, 충돌 조정 단순 |
| 합의 신호 | 출력 마지막 줄 `VERDICT: APPROVED` / `VERDICT: REVISE` | 구현 단순 + 사람이 읽기 쉬움 |
| 트리거 | `/fusion <task>` 와 `/fusion` 두 모드 | 사전·사후 검증 시나리오 모두 커버 |
| 상태 저장 | `/tmp/fusion-<ts>-<rand>/` | 사후 재현·디버깅, 세션 컨텍스트 압박 회피 |

## 4. 파일 레이아웃

```
CodexClaudeFusion/
├── skills/
│   └── fusion/
│       ├── SKILL.md            # 핑퐁 루프 명세 (Claude가 따라감)
│       ├── prompts/
│       │   ├── reviewer.md     # Codex 시스템 프롬프트
│       │   └── revise.md       # REVISE 라운드용 템플릿
│       └── lib/
│           └── parse-verdict.sh
├── tests/
│   └── parse-verdict.bats      # 마커 파싱 단위 테스트
├── install.sh                  # ~/.claude/skills/fusion 심볼릭 링크 생성
├── docs/superpowers/specs/
│   └── 2026-05-08-codex-claude-fusion-design.md
├── README.md
└── .gitignore
```

본체는 본 레포에서 버전 관리하고, `install.sh`로 `~/.claude/skills/fusion → 본 레포의 skills/fusion` 심볼릭 링크를 생성한다. 모든 사용자 프로젝트(athens-gate-fw, GateReader 등)에서 `/fusion`을 호출할 수 있다.

### 의존성
- `codex` CLI ≥ 0.128.0 (검증 완료: `/opt/homebrew/bin/codex`)
- `git`
- 기타 무의존 (zero-deps 원칙)

## 5. SKILL.md 핑퐁 루프 명세

### 5.1 입력 파싱

```
/fusion                         → diff 모드: working tree + git diff HEAD를 검증
/fusion <task description>      → task 모드: Claude가 1차 구현 후 검증
/fusion --max-rounds N          → 안전망 (기본 3)
/fusion --files <glob>          → 특정 파일에 한정 (선택)
```

### 5.2 라운드 루프 의사코드

```
# 0. 작자 라운드 (Claude) — task 모드일 때만
if mode == "task":
    Claude가 task 묘사대로 Edit/Write로 1차 구현

# 1. 라운드 루프
for round in 1..max_rounds:

    # (a) 검토자 라운드 — Codex
    diff = `git diff HEAD`
    prompt = render(reviewer.md, task, prev_history, diff)
    output = `codex exec --skip-git-repo-check --sandbox read-only "$prompt"`

    # (b) VERDICT 파싱
    verdict = lib/parse-verdict.sh "$output"
    if verdict == "APPROVED":
        break
    elif verdict == "REVISE":
        feedback = output (마커 위까지)
    else:
        fail("VERDICT 마커 없음")

    # (c) 작자 응답 라운드 — Claude
    Claude가 feedback을 읽고 수용/거부 판단, Edit/Write로 코드 수정
    Claude가 한 줄 요약 기록 (round-N-claude.txt)

# 2. 종료
if verdict == "APPROVED":
    "✅ FUSION COMPLETE in N rounds"
else:
    "⚠️ MAX ROUNDS REACHED — 미해결 이슈: ..."
```

### 5.3 가드레일 (SKILL.md에 명시)

- **Codex 피드백을 무조건 수용 금지**: 명백히 잘못된 지적은 거부하고 한 줄 이유를 `round-N-claude.txt`에 기록
- **scope creep 금지**: 작자 응답 라운드는 피드백 반영 전용, 새 기능 추가 안 함
- **VERDICT 마커 없으면 추측 분류 금지**: 즉시 명시적 에러로 종료

## 6. 데이터 흐름

### 6.1 Codex 호출 명령

```bash
codex exec --skip-git-repo-check --sandbox read-only "$(cat reviewer-prompt.txt)"
```

`--sandbox read-only`로 Codex가 파일을 수정하지 못하게 강제한다. 수정은 오직 Claude만.

### 6.2 `reviewer.md` 골격

```
You are Codex, acting as the reviewer in a Claude↔Codex pingpong loop.
Author is Claude. You DO NOT modify code; you only review.

CONTEXT
- Task: {TASK_OR_DIFF_MODE}
- Previous rounds:
{PREV_HISTORY_OR_EMPTY}

CURRENT DIFF
```diff
{GIT_DIFF_HEAD}
```

OUTPUT FORMAT (strict)
1. Overview (1-3 lines)
2. Issues by severity:
   - BLOCKER: <file:line> — what — why — suggested fix
   - MAJOR:   ...
   - MINOR:   ...
   (write "No actionable issues." if all empty)
3. Final line MUST be EXACTLY one of:
   VERDICT: APPROVED
   VERDICT: REVISE

RULES
- APPROVED only when no BLOCKER/MAJOR remain. Style preferences alone ≠ REVISE.
- Reference real lines from the diff. Do not invent code.
```

### 6.3 라운드 간 상태 (디스크)

```
/tmp/fusion-<unix_ts>-<rand4>/
├── task.txt                # task 모드일 때만
├── round-1-codex.txt       # Codex 출력 전체
├── round-1-claude.txt      # Claude의 1줄 요약 (수용/기각 + 이유)
├── round-2-codex.txt
├── ...
└── final.txt               # APPROVED 또는 MAX_ROUNDS, 라운드 수, 경과시간
```

종료 후 사용자에게 경로 안내. 사후 검토·재현 가능.

### 6.4 라운드별 diff 정책

- 매 라운드 동일하게 `git diff HEAD` 사용
- `commit`/`stash` 안 함 → working tree와 사용자 git 흐름을 방해하지 않음
- 누적 컨텍스트는 `PREV_HISTORY` 섹션의 `round-N-claude.txt` 요약으로 전달

### 6.5 Claude→Codex 핸드오프 요약 형식

`round-N-claude.txt` 예시:
```
applied: BLOCKER #1 (null check), MAJOR #2 (ISR re-entry guard)
rejected: MINOR #3 — reason: 기존 매크로 정책과 충돌
```

다음 라운드 reviewer.md의 `PREV_HISTORY`에 주입되어 Codex가 자기 지적의 처리 결과를 본다.

### 6.6 `parse-verdict.sh` 명세

표준입력 또는 인자로 받은 텍스트의 **마지막 비어있지 않은 줄**을 검사:
- `VERDICT: APPROVED` (정확 매칭, 양 끝 공백 trim) → stdout `APPROVED`, exit 0
- `VERDICT: REVISE` → stdout `REVISE`, exit 0
- 그 외 → stdout `UNKNOWN`, exit 1

호출자는 exit 1 이면 §7의 "VERDICT 마커 없음" 정책으로 즉시 종료한다.

### 6.7 사용자 출력

라운드마다:
```
== Round 1 / 3 ==
Codex review: 2 BLOCKER, 1 MAJOR, 0 MINOR (자세히는 round-1-codex.txt)
Applying: ...
== Round 2 / 3 ==
Codex review: No actionable issues. VERDICT: APPROVED
✅ FUSION COMPLETE in 2 rounds (state: /tmp/fusion-1715000000-a1b2/)
```

## 7. 에러 처리 / 엣지 케이스

| 케이스 | 처리 |
|---|---|
| `codex` CLI 부재 | 진입 시점 `command -v codex` 체크 → 부재 시 명시적 안내 후 종료 |
| `codex exec` 실패 (네트워크·인증) | 한 번 재시도, 두 번째도 실패 시 즉시 종료. stderr를 `round-N-codex.txt`에 보존 |
| VERDICT 마커 없음 | 즉시 에러: "Codex 출력에 VERDICT 누락. 프롬프트 실패 가능성." 자동 추측 금지 |
| diff 모드인데 working tree 깨끗 | "변경사항 없음" 안내 후 즉시 종료 |
| task 모드인데 Claude가 변경 못 함 | 라운드 1 진입 전 빈 diff 감지 → "task가 모호한지 확인" |
| 사용자 Ctrl+C | working tree·임시 디렉토리 보존, `final.txt`에 마지막 라운드 번호 기록 |
| MAX_ROUNDS 도달 | 정상 종료 분기. 미해결 BLOCKER/MAJOR 출력, 수동 검토 요청 |
| 매우 큰 diff (>500 LOC) | 경고만 출력하고 진행. 자동 분할은 Phase 외 |

## 8. 검증 전략

### 8.1 자동 단위 테스트 (`lib/parse-verdict.sh`)

`tests/parse-verdict.bats`로 케이스 검증:
- 정상: `VERDICT: APPROVED`, `VERDICT: REVISE`
- 비정상: 마커 없음, 마커가 마지막 줄 아님, 대소문자 변형, 공백 변형 (모두 §7 "VERDICT 마커 없음" 분기로 흘려 즉시 종료)

### 8.2 시나리오 dogfooding (수동, 결과를 README에 기록)

| 시나리오 | 기대 결과 |
|---|---|
| S1: task 모드 — "C로 ring buffer push" | 1~2 라운드 내 APPROVED |
| S2: diff 모드 — 의도적 off-by-one 버그 심음 | Codex가 BLOCKER로 잡고 수정 후 APPROVED |
| S3: 이미 잘 짜인 코드에 `/fusion` | 1라운드 즉시 APPROVED |
| S4: 양립 불가 요구사항 강제 | MAX_ROUNDS 도달, 미해결 이슈 보고 |
| S5: `codex` 미설치 환경 | 명시적 에러, 라운드 진입 없음 |

### 8.3 실전 인수 기준 (Phase 1 → Phase 2 진입 게이트)

`athens-gate-fw` 또는 `GateReader`의 실제 변경 1건 이상을 `/fusion`으로 검증하여:
- 합의 도달 (또는 정상 MAX_ROUNDS) 1회 이상 성공
- 사용자 만족도 확인 후 Phase 2 (hook 자동화) 착수

## 9. 후속 단계 로드맵 (참고)

| Phase | 내용 | Phase 1 의존성 |
|---|---|---|
| 2 | `PostToolUse` hook 자동 트리거. 노이즈 컨트롤(파일 패턴, 변경량 임계치). | 5절 핑퐁 루프 그대로 재사용 |
| 3 | 펌웨어 특화 룰셋 (ARM/embedded, ISR 안전성, 메모리 정렬, watchdog 등) → `reviewer.md`에 주입 | 6.2절 프롬프트 슬롯 그대로 |
| 4 | `systematic-debugging` 가설/반증 분담, TDD 테스트→구현 분담 모드 추가 | 5절 루프에 모드 분기 추가 |

## 10. 결정 사항 트레이스 (이번 브레인스토밍에서 확정)

1. 4개 Phase 중 Phase 1만 우선
2. Codex 호출은 `codex exec` CLI 직접
3. 종료 조건: 합의 감지 + 최대 N라운드
4. 역할: 작자=Claude, 검토자=Codex 고정
5. 합의 신호: 출력 마지막 줄 `VERDICT:` 마커
6. 트리거: `/fusion <task>` (작업+검증), `/fusion` (diff 검증) 두 모드
7. 오케스트레이션: 인-세션 슬래시 스킬 (외부 데몬 없음)
