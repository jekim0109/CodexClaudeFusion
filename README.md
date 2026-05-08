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
