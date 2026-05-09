# Codex–Claude Fusion (Phase 3) 설계 스펙

- **작성일**: 2026-05-09
- **상태**: Draft → 사용자 리뷰 대기
- **범위**: Phase 3 펌웨어 특화 룰셋 MVP (Phase 3.x는 후속)
- **Phase 1·2 의존성**: master 시점 (30+ 커밋, 36 tests pass, A1~A5 dogfooding 통과)

## 1. 동기

Phase 1·2는 일반 코드 리뷰에 강하지만, athens-gate-fw·GateReader 같은 ARM Cortex-M 펌웨어 코드의 도메인 위반(ISR 안에서 sleep, volatile 누락 등)은 base reviewer.md 룰만으로는 일관되게 잡히지 않는다. Phase 3는 펌웨어 도메인 룰을 prompt에 주입해 ISR/race + Volatile 정확성을 표적 검토하도록 한다.

핵심 원칙:
- **Project-local opt-in** (Phase 2와 동일 사상): 일반 프로젝트에 노이즈 영향 없음
- **base reviewer.md 무변경**: Phase 1·2 회귀 위험 0
- **별도 룰 파일 append**: firmware-rules.md를 prompt 끝에 조건부로 덧붙임

## 2. 범위와 비범위

### Phase 3에 포함
- `firmware-rules.md` 신규 파일 (ISR/race + Volatile 룰 ~30~40줄)
- `.claude/settings.json` 의 `fusion.firmware: true` 플래그
- `enable-firmware.sh` / `disable-firmware.sh` opt-in/out 스크립트
- Hook (`auto-review-hook.sh`) + SKILL.md (수동 `/fusion`) 양쪽 모두 prompt 합성 단계에 firmware 분기 추가
- 단위 테스트 (`tests/firmware-mode.test.sh`)
- README "펌웨어 모드 (Phase 3)" 섹션

### Phase 3 비범위 (Phase 3.x)
- DMA·Watchdog·Static memory 룰
- 자동 감지 (Makefile 패턴 등)
- 사용자 정의 룰 파일 (`.claude/fusion-rules/custom.md`)
- 룰셋 버전 관리·diff
- prompt 합성 helper 분리 (Hook과 SKILL.md 코드 통합)

### 명시적 비목표
- base reviewer.md 변경
- 룰셋이 일반 프로젝트에 자동 적용 (Project-local opt-in 강제)
- BLOCKER/MAJOR/MINOR 외 새 심각도 분류 (기존 분류 + `(A.ISR)` `(B.VOL)` prefix만 추가)

## 3. 아키텍처 결정 요약

| 항목 | 결정 | 이유 |
|---|---|---|
| 활성화 트리거 | Project-local opt-in (`.claude/settings.json`) | Phase 2 패턴 재사용, 일반 프로젝트 격리 |
| 룰 통합 방식 | 별도 `firmware-rules.md` + 조건부 append | base 무변경, 회귀 위험 0, 확장 쉬움 |
| 룰 카테고리 | A.ISR/race + B.VOL 두 가지만 | YAGNI, MVP 우선; DMA·Watchdog·Static은 후속 |
| 심각도 매핑 | 룰별로 BLOCKER/MAJOR/MINOR 명시 | 분류 일관성 확보 |
| 카테고리 prefix | `BLOCKER (A.ISR):` 같은 형식 | 사용자가 한 눈에 펌웨어 이슈 식별 |
| settings.json 손상 처리 | try/except로 firmware=false fallback | hook 안정성 (silent fallback) |

## 4. 파일 레이아웃

### 신규 산출물
```
CodexClaudeFusion/
├── skills/fusion/
│   └── prompts/
│       └── firmware-rules.md        # 룰셋 본체
├── enable-firmware.sh                # project opt-in
├── disable-firmware.sh               # project opt-out
├── tests/
│   └── firmware-mode.test.sh         # prompt 합성 분기 검증
├── README.md                         # "펌웨어 모드 (Phase 3)" 섹션 추가
└── docs/superpowers/specs/2026-05-09-codex-claude-fusion-phase3-design.md
```

### 기존 파일 변경
- `skills/fusion/lib/auto-review-hook.sh` — python heredoc에 firmware 분기 추가 (~15줄)
- `skills/fusion/SKILL.md` — 동일 분기 추가 + bash 측 `PROJECT_ROOT` export

### 무변경 (Phase 1)
- `skills/fusion/prompts/reviewer.md`
- `skills/fusion/lib/parse-verdict.sh`

### 의존성
Phase 2와 동일 (`codex` ≥ 0.128.0, `git`, `bash`, `python3`, `shasum`). 추가 없음.

## 5. `firmware-rules.md` 룰셋 본체

`reviewer.md` 끝에 append되는 추가 검토 지침. 기존 BLOCKER/MAJOR/MINOR 형식 재사용 + `(A.ISR)` / `(B.VOL)` prefix.

```
FIRMWARE-SPECIFIC REVIEW RULES (active when fusion.firmware = true)

In addition to the general review rules above, also check the following.
When you report a firmware-specific issue, prepend the category to the
severity label, e.g.:
   BLOCKER (A.ISR): src/foo.c:42 — ...
   MAJOR (B.VOL):   src/bar.c:17 — ...

A. ISR safety and race conditions

- ISR must not block or sleep. No busy-wait beyond a few cycles, no
  malloc/free, no mutex acquire on a lock that mainline may hold,
  no printf or other I/O that may block. → BLOCKER if found.
- Long ISR work: heavy computation or long loops in ISR context →
  MAJOR (consider deferred work via a flag + main loop or task).
- ISR-shared state: any variable read or written by both ISR and main
  must be (a) qualified `volatile` AND (b) accessed atomically — single
  32-bit load/store on Cortex-M, or wrapped in a critical section.
  Missing either → MAJOR.
- Memory ordering: when DMA buffers or peripheral state cross ISR↔main,
  flag missing memory barrier (DMB/DSB/ISB) or compiler barrier where
  ordering is required → MAJOR.
- Critical sections: must be short and balanced (enable matches every
  disable). Early return between disable and enable → BLOCKER.
- ISR re-entrancy: nested same-vector calls without explicit guard →
  BLOCKER if state is shared.

B. Volatile correctness

- Hardware register access (memory-mapped peripherals) MUST use
  `volatile`. Missing → BLOCKER (read/write may be optimized away).
- ISR-shared variables (see A above) — missing `volatile` → MAJOR.
- `volatile` is NOT atomic. Flag any use of `volatile` as a substitute
  for synchronization → MAJOR.
- `volatile T*` vs `T* volatile` distinction: confirm declaration
  matches the intent (pointee mutable vs pointer mutable). Mismatch
  → MAJOR.
- Redundant volatile (local non-shared variable, etc.) → MINOR.

Style preferences alone (e.g. naming, indentation) are NOT grounds for
REVISE — the base rules above already say so. Only flag firmware
concerns when the diff plausibly creates the hazard.
```

### 약속·제약
- 길이 ~30~40줄. base reviewer.md(~30줄)와 합쳐도 prompt가 무겁지 않음.
- 슬롯 토큰(`{{...}}`) 사용 금지 — slot 치환 이후 append되므로 의도치 않은 치환 방지.
- BLOCKER/MAJOR/MINOR 라벨 형식이 `parse-verdict.sh`의 카운트 regex와 호환 (Phase 2 fix 후 dash 옵셔널 + 들여쓰기 옵셔널).

## 6. 활성화 메커니즘

### `.claude/settings.json` 구조
```json
{
  "hooks": { ... },
  "fusion": {
    "firmware": true
  }
}
```

`fusion.firmware: true`만 의미 있는 신호.

### `enable-firmware.sh` 동작 (Phase 2 enable-auto.sh 패턴)

1. cwd 또는 인자 PROJECT
2. `.claude/` 없으면 mkdir
3. settings.json 없으면 `{}`로 시작
4. 기존 파일을 `.bak`로 백업
5. python3 안전 병합:
   ```python
   data.setdefault("fusion", {})["firmware"] = True
   ```
6. JSON 손상 시 `.bak로 복원하세요` 안내 + exit 1
7. 안내: `Firmware mode enabled in <project>. Rules: ISR/race + Volatile correctness.`

### `disable-firmware.sh` 동작

1. settings.json 없으면 `not enabled` 후 exit 0
2. `.bak` 백업
3. python3로 `data.get("fusion", {}).pop("firmware", None)`
4. fusion 객체 비면 키 자체 제거 (다른 fusion sub-keys 없을 때만)
5. JSON 손상 시 `.bak로 복원하세요` 안내 + exit 1
6. 안내: `Firmware mode disabled.`

### 식별·중복 방지

- enable: `data["fusion"]["firmware"] == True` 이미면 noop
- disable: 키 부재면 noop
- 사용자 다른 fusion sub-keys (예: 향후 Phase 3.x의 `fusion.rules_path`)는 보존

## 7. Hook + SKILL.md prompt 합성 분기

기존 python heredoc의 슬롯 치환 직후에 다음 코드 삽입:

```python
# Firmware-mode rules append (Phase 3)
project_root = os.environ.get("PROJECT_ROOT", "")
settings_path = os.path.join(project_root, ".claude", "settings.json") if project_root else ""
firmware = False
if settings_path and os.path.isfile(settings_path):
    try:
        with open(settings_path) as f:
            cfg = json.load(f)
        firmware = cfg.get("fusion", {}).get("firmware") is True
    except Exception:
        firmware = False

if firmware:
    rules_path = os.path.join(os.environ.get("SKILL_DIR", ""), "prompts", "firmware-rules.md")
    if os.path.isfile(rules_path):
        with open(rules_path) as f:
            s += "\n\n" + f.read()
```

bash 측에서 `PROJECT_ROOT`, `SKILL_DIR` 둘 다 export.

### Hook (`auto-review-hook.sh`) 변경
- 이미 `PROJECT_ROOT`, `SKILL_DIR` 정의됨 → `export PROJECT_ROOT SKILL_DIR` 추가하고 python 분기 삽입

### SKILL.md (수동 `/fusion`) 변경
- 이미 `SKILL_DIR` 정의됨
- `PROJECT_ROOT=$(git rev-parse --show-toplevel)` 추가
- `export PROJECT_ROOT` 추가
- python 분기 삽입 (hook과 동일)

### 분기 삽입 위치 (정확히)
- `auto-review-hook.sh`: 섹션 5 "Codex call" 블록의 python heredoc 안, 슬롯 치환 3개 직후
- `SKILL.md`: §3.a 검토자 라운드의 python heredoc 안, 슬롯 치환 3개 직후

### 두 곳 동기화
- 동일 분기 코드를 두 파일에 복제. ~15줄.
- 향후 분리(예: `lib/render-prompt.py`)는 Phase 3.x.

## 8. 에러 처리 / 엣지 케이스

| 케이스 | 처리 |
|---|---|
| `.claude/settings.json` 없음 | base mode (firmware off) |
| settings.json은 있으나 `fusion` 키 없음 | base mode |
| `fusion.firmware`가 false 또는 누락 | base mode |
| `fusion.firmware`가 true이지만 `firmware-rules.md` 부재 | base만 사용, hook 정상 진행 |
| settings.json JSON 손상 | python try/except로 firmware=false fallback |
| `PROJECT_ROOT` 비어있음 (git rev-parse 실패) | settings.json 검사 안 함, base mode |
| enable/disable 중 settings.json 손상 | `.bak` 복원 안내 + exit 1 (Phase 2 패턴) |
| firmware-rules.md 빈 파일 | append되지만 효과 없음 (해롭지 않음) |
| firmware-rules.md에 슬롯 토큰(`{{...}}`) | slot 치환 *이후* append → 그대로 codex에 전달. **MVP는 슬롯 사용 금지** |

## 9. 검증 전략

### 자동 단위 테스트 — `tests/firmware-mode.test.sh`

| 케이스 | 기대 |
|---|---|
| settings.json `fusion.firmware:true` → prompt에 firmware section 포함 | `grep "FIRMWARE-SPECIFIC REVIEW RULES"` 매칭 |
| settings.json `fusion.firmware:false` | 매칭 없음 |
| settings.json 부재 | 매칭 없음 |
| settings.json JSON 손상 | 매칭 없음, hook exit 0 |
| `enable-firmware.sh` → 키 추가, 기존 hooks·다른 키 보존 | python predicate 검증 |
| `enable-firmware.sh` 재실행 → idempotent | 동일 |
| `disable-firmware.sh` → 키 제거, 다른 키 보존 | 검증 |
| `disable-firmware.sh` → settings.json 부재 시 graceful exit 0 | 검증 |

테스트는 stub codex로 hook을 실행하고 `$FUSION_DIR/round-1-prompt.txt`를 읽어 firmware section 포함 여부 검사 (Phase 2 sentinel 메커니즘 재사용).

### 시나리오 dogfooding (수동, 결과를 README에 기록)

| 시나리오 | 기대 |
|---|---|
| F1: enable-firmware → ISR 함수에 `printf` 추가한 buggy 코드 → /fusion | `BLOCKER (A.ISR)` 출력 |
| F2: enable-firmware → ISR-shared 변수에 volatile 누락 → /fusion | `MAJOR (B.VOL)` 또는 `MAJOR (A.ISR)` |
| F3: disable-firmware → 같은 buggy 코드 → /fusion | base mode (펌웨어 prefix 없음) |
| F4: enable-firmware → 일반 .c 변경 (펌웨어 무관) | base + firmware 룰 모두 적용, 위반 없으면 APPROVED |

### Phase 3 → Phase 3.x 진입 게이트

`athens-gate-fw` 또는 `GateReader`의 실제 변경 1건에 firmware mode 적용해 ISR/Volatile 이슈를 (있으면) 잡거나, 없으면 false positive 없는 APPROVED 결과 확인.

## 10. 후속 단계 로드맵 (참고)

| Phase | 내용 | Phase 3 의존성 |
|---|---|---|
| 3.x | DMA·Watchdog·Static memory 룰 추가 | firmware-rules.md에 항목 추가 |
| 3.x | 자동 감지 (Makefile 패턴 등) | 활성화 메커니즘 확장 |
| 3.x | 사용자 정의 룰 파일 (`.claude/fusion-rules/custom.md`) | prompt 합성에 추가 분기 |
| 3.x | prompt 합성 helper 분리 (`lib/render-prompt.py`) | hook과 SKILL.md 코드 통합 |
| 4 | systematic-debugging / TDD 통합 | reviewer.md 확장 + 모드 분기 |

## 11. 결정 사항 트레이스 (이번 브레인스토밍 확정)

1. 활성화 방식: Project-local opt-in (`.claude/settings.json`의 `fusion.firmware`)
2. 룰 카테고리: A.ISR/race + B.VOL (DMA·Watchdog·Static memory는 후속)
3. 룰 통합 방식: 별도 `firmware-rules.md` + 조건부 append (base 무변경)
4. 심각도 매핑: 룰별 BLOCKER/MAJOR/MINOR 명시 + `(A.ISR)` `(B.VOL)` prefix
5. 분기 위치: hook과 SKILL.md 양쪽 python heredoc (코드 복제, helper 분리는 후속)
6. 에러 처리: settings.json·rules 부재/손상 모두 base mode silent fallback
