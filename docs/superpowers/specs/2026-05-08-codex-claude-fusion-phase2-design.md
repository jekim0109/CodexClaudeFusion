# Codex–Claude Fusion (Phase 2) 설계 스펙

- **작성일**: 2026-05-08
- **상태**: Draft → 사용자 리뷰 대기
- **범위**: Phase 2 자동 리뷰 hook MVP (Phase 3·4는 후속)
- **Phase 1 의존성**: master `44c4cc9` 시점 (16커밋, dogfooding 통과)

## 1. 동기

Phase 1의 `/fusion` 슬래시 스킬은 사용자가 명시적으로 호출해야 동작한다. 활발한 개발 중에는 호출을 깜빡하거나 작은 실수가 누적된 뒤에야 검증을 받는다. Phase 2는 Claude의 응답이 끝나는 시점마다 **무손·저노이즈로 자동 리뷰**가 수행되어 회귀를 조기에 잡도록 한다.

핵심 원칙: 자동화는 **review-only**다. Codex가 검토하고 결과를 한 줄 알리되, 코드 수정은 Phase 1처럼 사용자가 명시적으로 `/fusion` 호출 시에만 진행한다.

## 2. 범위와 비범위

### Phase 2에 포함
- Stop hook으로 자동 발동 (응답 끝 1회)
- Codex 리뷰 1라운드 (PREV_HISTORY 없음)
- 4종 노이즈 필터 — 변경 없음 / 변경량 임계치 / 파일 패턴 / diff 해시 캐시
- 한 줄 결과 출력 (REVISE면 BLOCKER/MAJOR/MINOR 카운트 + state 경로)
- Project-local opt-in (`enable-auto.sh` / `disable-auto.sh`)
- Phase 1 산출물(`parse-verdict.sh`, `reviewer.md`) 무변경 재사용

### Phase 2 비범위 (별도 단계)
- 자동 코드 수정 (Phase 1처럼 사용자가 `/fusion` 명시 호출로만)
- 비동기/백그라운드 실행 (동기 5~10초 대기 수용)
- BLOCKER 발견 시 자동 `/fusion` 핑퐁 시작
- Phase 3 펌웨어 룰셋 통합 (별도 단계)
- 사용자 정의 패턴 settings 키 (Phase 2.x로 미룸; MVP는 hardcoded blocklist만)
- ALLOW 명시 리스트 (Phase 2.x; MVP는 "BLOCK이 아니면 통과")

### 명시적 비목표
- PostToolUse 매번 발동 (노이즈 폭발 위험으로 Stop hook으로 결정)
- Global 자동 활성화 (project-local opt-in으로 격리)
- 모든 자동 분기에 명시적 에러 출력 (hook은 silent exit이 원칙)

## 3. 아키텍처 결정 요약

| 항목 | 결정 | 이유 |
|---|---|---|
| 발동 시점 | `Stop` hook (응답 끝) | PostToolUse 대비 노이즈 적고 자연스러운 단위 |
| 자동화 범위 | Codex 리뷰 1라운드만 | Claude 자동 수정 위험 회피 |
| 노이즈 필터 | 4종 (변경/임계치/패턴/캐시) | 단발 펌웨어 작업의 스팸 차단 |
| 출력 형식 | 한 줄 + REVISE면 state 경로 | 정상 일에 최소 자국 |
| 토글·스코프 | Project-local opt-in (`.claude/settings.json`) | 모든 프로젝트 자동 활성화 사고 방지 |
| 캐시 위치 | `<project>/.fusion-cache.txt` | project-local 격리, .gitignore 안내 |
| 비정상 분기 | 모두 silent exit 0 | hook이 사용자 흐름 방해 안 함 |

## 4. 파일 레이아웃

```
CodexClaudeFusion/
├── skills/fusion/
│   └── lib/
│       └── auto-review-hook.sh    # Stop hook 진입점 (새)
├── enable-auto.sh                  # project opt-in (새)
├── disable-auto.sh                 # project opt-out (새)
├── tests/
│   └── auto-review-hook.test.sh    # bash 테스트 (새)
├── README.md                       # "자동 리뷰" 섹션 추가
└── docs/superpowers/specs/2026-05-08-codex-claude-fusion-phase2-design.md
```

사용자 프로젝트 측 (`enable-auto.sh`가 생성):

```
<user-project>/
├── .claude/
│   └── settings.json               # hook 등록 (병합/생성)
└── .fusion-cache.txt               # diff 해시 캐시 (한 줄에 한 hash)
```

`.fusion-cache.txt`는 `.gitignore`에 자동 추가되며, README에 안내.

### Phase 1 산출물 재사용
- `skills/fusion/lib/parse-verdict.sh` — 그대로 호출
- `skills/fusion/prompts/reviewer.md` — 그대로 사용 (PREV_HISTORY 슬롯에 항상 `(none)` 주입)
- `~/.claude/skills/fusion` 심볼릭 링크 — 그대로 (hook도 이 경로 참조)

### 의존성
Phase 1과 동일: `codex` ≥ 0.128.0, `git`, `bash`, `python3`, `shasum`(macOS 기본). 추가 없음.

## 5. Hook 등록 메커니즘

### Claude Code Stop hook 표준 형식

`.claude/settings.json`:
```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh"
          }
        ]
      }
    ]
  }
}
```

### `enable-auto.sh` 동작

1. cwd 또는 인자로 받은 프로젝트 루트로 이동
2. `.claude/` 디렉토리 없으면 생성
3. `.claude/settings.json` 없으면 `{}` 로 시작
4. 기존 파일을 `.claude/settings.json.bak` 으로 백업
5. python3로 안전 병합:
   - `hooks.Stop` 배열에 우리 entry 없으면 추가
   - 이미 있으면 noop ("already enabled")
6. `.gitignore`에 `.fusion-cache.txt` 라인 없으면 추가 (있으면 건드리지 않음)
7. 안내 메시지: `"Auto-review enabled in <project>. Use disable-auto.sh to turn off."`

### `disable-auto.sh` 동작

1. `.claude/settings.json` 없으면 "not enabled" 안내 후 exit 0
2. python3로 JSON 편집:
   - `hooks.Stop` 에서 fusion entry 제거 (정확 매칭)
   - `hooks.Stop` 비면 키 자체 제거
   - `hooks` 객체 비면 키 자체 제거
3. 빈 `.claude/settings.json` 보존 (사용자 다른 설정 보존; 우리가 만든 거라도 다른 entry 없으면 그대로 둠)
4. `.fusion-cache.txt` 보존 (다음 enable 시 재사용)
5. 안내 메시지: `"Auto-review disabled."`

### 식별·중복 방지

우리 entry를 식별하는 기준은 **command 문자열의 정확 매칭**:

```
bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh
```

- enable: 위 command를 가진 entry가 있으면 추가 안 함
- disable: 같은 기준으로 entry 골라 제거
- 사용자가 직접 다른 인자·플래그로 hook을 등록했다면 우리 것이 아니라고 판단 → 보존

### 안전성 원칙
- 사용자 기존 hook entries 무손
- JSON round-trip은 python `json` 모듈 (포맷 보존은 보장 안 되지만 데이터 무손)
- 모든 enable·disable 시작 시 `.bak` 한 부

## 6. `auto-review-hook.sh` 본체

### 흐름 (의사코드)

```bash
#!/usr/bin/env bash
set -u

# 0. 사전 점검 (실패 시 silent exit 0)
command -v codex >/dev/null 2>&1 || exit 0
command -v git   >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
SKILL_DIR="$HOME/.claude/skills/fusion"
[[ -d "$SKILL_DIR" ]] || exit 0

PROJECT_ROOT=$(git rev-parse --show-toplevel)
CACHE_FILE="$PROJECT_ROOT/.fusion-cache.txt"

# 1. 필터 (a) — 변경 없음 skip
DIFF_TEXT="$(git diff HEAD 2>/dev/null)"
[[ -z "$DIFF_TEXT" ]] && exit 0

# 2. 필터 (b) — 변경량 임계치
DIFF_LINES=$(printf '%s\n' "$DIFF_TEXT" | wc -l)
(( DIFF_LINES < 3 )) && exit 0
if (( DIFF_LINES > 500 )); then
    echo "[fusion] 변경 ${DIFF_LINES}줄 (>500). 자동 리뷰 skip — /fusion 수동 호출 권장."
    exit 0
fi

# 3. 필터 (c) — 파일 패턴 (MVP: blocklist only)
BLOCK=( "*.md" "*.txt" "*.json" "*.lock" "*.log" "*.bak"
        "package-lock.json" "yarn.lock" "Cargo.lock" "pnpm-lock.yaml" )
# 정책: 변경 파일 중 BLOCK에 매칭되지 않는 파일이 1개 이상 있으면 진행.
#       모든 변경 파일이 BLOCK 매칭이면 silent skip.
# (Phase 2.x에서 .claude/settings.json 의 사용자 정의 allow/block 배열로 override)

# 4. 필터 (d) — diff 해시 캐시
DIFF_HASH=$(printf '%s' "$DIFF_TEXT" | shasum -a 256 | awk '{print $1}')
[[ -f "$CACHE_FILE" ]] && grep -qx "$DIFF_HASH" "$CACHE_FILE" && exit 0

# 5. Codex 호출 (Phase 1과 동일 패턴)
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
with open(tmpl_path) as f: s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])
with open(out_path, "w") as f: f.write(s)
PYEOF

SECONDS=0
if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2> "$FUSION_DIR/round-1-codex.stderr"; then
    sleep 1
    if ! codex exec --skip-git-repo-check --sandbox read-only -o "$LAST_MSG_FILE" - < "$PROMPT_FILE" 2>> "$FUSION_DIR/round-1-codex.stderr"; then
        exit 0   # silent: hook은 best-effort
    fi
fi
ELAPSED=$SECONDS

# 6. VERDICT 파싱
VERDICT=$(bash "$SKILL_DIR/lib/parse-verdict.sh" < "$LAST_MSG_FILE")

# 7. 캐시 기록 (성공 라운드만)
echo "$DIFF_HASH" >> "$CACHE_FILE"
tail -n 100 "$CACHE_FILE" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"

# 8. 출력
case "$VERDICT" in
    APPROVED)
        echo "[fusion] ✓ auto-review APPROVED (${ELAPSED}s)"
        ;;
    REVISE)
        BLOCKERS=$(grep -c '^- BLOCKER:' "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        MAJORS=$(grep -c '^- MAJOR:'   "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        MINORS=$(grep -c '^- MINOR:'   "$LAST_MSG_FILE" 2>/dev/null || echo 0)
        echo "[fusion] ⚠ auto-review REVISE — ${BLOCKERS} BLOCKER, ${MAJORS} MAJOR, ${MINORS} MINOR (state: $FUSION_DIR)"
        ;;
    *)
        exit 0   # 마커 누락은 silent (hook 안정성)
        ;;
esac
exit 0
```

### 주요 결정 디테일
- **모든 비정상 분기 silent**: hook은 사용자 흐름 방해 X
- **응답 차단 시간**: codex 호출 5~10초 동기 실행. Phase 2 MVP는 단순함 우선; 비동기/백그라운드는 후속
- **PREV_HISTORY="(none)"**: 자동 리뷰는 단일 라운드라 이력 없음. reviewer.md 변경 없이 그대로
- **severity 카운트**: REVISE 한 줄에 BLOCKER/MAJOR/MINOR 개수 포함
- **캐시 cap**: `tail -n 100`로 마지막 100줄만 유지

## 7. 데이터 흐름

### diff 해시 캐시 형식
한 줄에 SHA-256 hex (64자):
```
<hash>
<hash>
<hash>
...
```
- 신규 hash는 append
- `tail -n 100`으로 cap (오래된 hash 자동 폐기)
- `.gitignore`에서 제외

### 출력 (사용자 화면에 보이는 것)
정상 시 한 줄. 예시:
```
[fusion] ✓ auto-review APPROVED (6s)
```
또는:
```
[fusion] ⚠ auto-review REVISE — 1 BLOCKER, 2 MAJOR, 0 MINOR (state: /tmp/fusion-1715000000-a1b2)
```

### `/tmp/fusion-<ts>-<rand>/` 산출물 (Phase 1과 동일 구조)
- `round-1-prompt.txt`
- `round-1-codex.txt`
- `round-1-codex.stderr` (codex 실패 시만)

`final.txt`는 자동 리뷰에서는 생략 (단일 라운드, 캐시로 결과 추적).

## 8. 에러 처리 / 엣지 케이스

| 케이스 | 처리 |
|---|---|
| codex/git CLI 부재 | silent exit 0 |
| 본 레포 미설치 | silent exit 0 |
| git 외부 | silent exit 0 |
| 빈 diff | silent exit 0 |
| 변경 파일 모두 BLOCK | silent exit 0 |
| 변경 <3 줄 | silent exit 0 |
| 변경 >500 줄 | 한 줄 안내 + skip |
| 동일 diff 캐시 hit | silent exit 0 |
| codex exec 1+1회 실패 | stderr 보존, silent exit 0 |
| VERDICT 마커 누락 | silent exit 0 (Phase 1과 다름; 자동은 noisy 안 됨) |
| settings.json 손상 | `.bak`로 복구 안내 + 명시적 에러 (enable/disable만) |
| `.fusion-cache.txt` 손상 | 새 빈 파일로 갈음 (best-effort) |

## 9. 검증 전략

### 자동 단위 테스트 — `tests/auto-review-hook.test.sh`

| 케이스 | 기대 |
|---|---|
| codex 미설치 (PATH 조작) | exit 0, 출력 없음 |
| git 외부에서 호출 | exit 0, 출력 없음 |
| 빈 diff | exit 0, 출력 없음 |
| diff 2줄 | exit 0, 출력 없음 |
| diff 600줄 | exit 0, 한 줄 경고만 |
| 변경 파일이 *.lock뿐 | exit 0, 출력 없음 (모두 BLOCK 매칭) |
| 변경 파일이 Makefile (BLOCK 미매칭) | codex 진입 직전까지 도달 |
| 변경 파일이 *.c (BLOCK 미매칭) | codex 진입 직전까지 도달 (실제 codex 호출은 stub) |
| 동일 diff 두 번째 호출 | 둘째는 silent (캐시 hit) |
| `enable-auto.sh` 신규 생성 | 정상 등록, 재실행 noop |
| `enable-auto.sh` 기존 hook entries 보존 | 다른 entries 무손상 |
| `disable-auto.sh` 정확 제거 | 우리 entry만 제거, 다른 entries 보존 |

Codex 호출 자체는 mock 어려우니 (외부 CLI), 위 케이스는 codex 진입 직전까지를 검증. 실제 codex는 dogfooding으로.

### 시나리오 dogfooding (수동, README에 기록)

| 시나리오 | 기대 |
|---|---|
| A1: opt-in → 작은 *.c 5줄 변경 → 응답 끝 | hook 발동, "[fusion] ✓ APPROVED" |
| A2: opt-in → buggy *.c (off-by-one) → 응답 끝 | "[fusion] ⚠ REVISE — 1 MAJOR..." |
| A3: opt-in → README만 수정 | 패턴 필터로 silent skip |
| A4: opt-in → 동일 diff로 두 번 응답 | 첫 회만 review, 둘째는 캐시로 silent |
| A5: disable-auto.sh 실행 → 변경 후 응답 | hook 미등록, 출력 없음 |

### Phase 2 → Phase 3 진입 게이트

athens-gate-fw 또는 GateReader 1건 이상에서 자동 리뷰 1회 성공 + 노이즈가 실제로 거슬리지 않는지 사용자 확인.

## 10. 후속 단계 로드맵 (참고)

| Phase | 내용 | Phase 2 의존성 |
|---|---|---|
| 2.x | 사용자 정의 패턴 settings 키 (`.claude/settings.json` 안의 `fusion.allow`/`fusion.block` 배열) | hook 본체에 패턴 로딩 추가 |
| 3 | 펌웨어 특화 룰셋 (ARM/embedded, ISR 안전성, watchdog) → `reviewer.md`에 주입 | hook 프롬프트 슬롯 그대로 |
| 4 | systematic-debugging 가설/반증 분담, TDD 모드 | hook은 그대로, SKILL.md 모드 분기 추가 |

## 11. 결정 사항 트레이스 (이번 브레인스토밍 확정)

1. 자동화 범위: Codex 리뷰 1라운드만 (full pingpong 아님)
2. 발동 시점: `Stop` hook (응답 끝, PostToolUse 아님)
3. 노이즈 필터 4종: 변경 없음 / 변경량(<3 또는 >500) / 파일 패턴 / diff 해시 캐시
4. 결과 표시: 항상 한 줄 + REVISE면 state 경로
5. 토글·스코프: Project-local opt-in (`.claude/settings.json`)
6. 구현 접근: 단일 bash hook + 내부 python heredoc (Phase 1 패턴 재사용)
