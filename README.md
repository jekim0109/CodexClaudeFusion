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

> 주의: diff 모드는 `git diff HEAD` 기준이라 untracked 파일은 자동 포함되지 않습니다. 신규 파일을 함께 검토하려면 `git add -N <파일>` 후 호출하거나 task 모드를 사용하세요.

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
| S1: task 모드 — "C로 ring buffer push" | 1~2 라운드 내 APPROVED | (추후 기록) |
| S2: diff 모드 — 의도적 off-by-one 버그 | Codex가 잡고 수정 후 APPROVED | ✅ Round 1 MAJOR(`i <= n`) → 수정 → Round 2 APPROVED, 총 ~16s |
| S3: 이미 잘 짜인 코드에 `/fusion` | 1라운드 즉시 APPROVED | ✅ Round 1 APPROVED, ~5s |
| S4: 양립 불가 요구사항 강제 | MAX_ROUNDS 도달, 미해결 이슈 보고 | (추후 기록) |
| S5: `codex` 미설치 환경 | 명시적 에러, 라운드 진입 없음 | ✅ `ERROR: codex CLI 미설치` + exit 1 |

S2·S3·S5 결과는 codex CLI 0.128.0 (gpt-5.5) 환경에서 2026-05-08 검증.

### 실전 펌웨어 dogfooding

**athens-gate-fw v8.5d (main `8493d79`) 격리 worktree에서 실행** — `src/AgmMain/utl/bsrch.c`의 binary-search 헬퍼 두 함수에 doc comment 37줄 보강(시그니처 무손).

- Round 1 결과: `Comment-only change documenting binary search helpers; no behavioral changes are introduced. No actionable issues. VERDICT: APPROVED` (8초)
- ✅ Phase 1 인수 기준 충족 — Phase 2(hook 자동화) 착수 가능

## 디자인 문서

- 스펙: `docs/superpowers/specs/2026-05-08-codex-claude-fusion-design.md`
- 구현 계획: `docs/superpowers/plans/2026-05-08-codex-claude-fusion-phase1.md`

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
- 변경 파일이 모두 blocklist (`*.md`, `*.txt`, `*.lock`, `*.log`, `*.bak`, `package-lock.json`, `yarn.lock`, `Cargo.lock`, `pnpm-lock.yaml`)
- 직전에 동일 diff를 이미 리뷰함 (`.fusion-cache.txt` 해시 캐시)

500줄 초과 변경은 한 줄 안내 후 skip — 수동 `/fusion` 권장.

### 검증 시나리오 (dogfooding)

| 시나리오 | 기대 결과 | 결과 |
|---|---|---|
| A1: opt-in → 작은 *.c 5줄 변경 → 응답 끝 | `[fusion] ✓ auto-review APPROVED (Ns)` 1라인 | (추후 기록) |
| A2: opt-in → buggy *.c (off-by-one) → 응답 끝 | `[fusion] ⚠ auto-review REVISE — N BLOCKER, M MAJOR, K MINOR (state: /tmp/fusion-...)` | (추후 기록) |
| A3: opt-in → README만 수정 | 패턴 필터로 silent | (추후 기록) |
| A4: 동일 diff로 두 번 응답 | 첫 회만 review, 둘째는 캐시 silent | (추후 기록) |
| A5: disable-auto.sh 후 변경 | hook 미등록, 출력 없음 | (추후 기록) |

## 후속 단계 로드맵

- **Phase 2**: Stop hook 자동 리뷰 (구현 진행 중 — 위 "자동 리뷰" 섹션 참조)
- **Phase 3**: 펌웨어 특화 룰셋 (ARM/embedded, ISR, watchdog)
- **Phase 4**: systematic-debugging / TDD 통합

## 라이선스

(미정)
