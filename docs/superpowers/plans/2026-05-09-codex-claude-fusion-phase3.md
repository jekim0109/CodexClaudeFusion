# Codex–Claude Fusion (Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project-local opt-in으로 펌웨어 특화 룰셋(ISR/race + Volatile)을 reviewer.md prompt 끝에 조건부 append하는 firmware mode를 빌드한다.

**Architecture:** 별도 `firmware-rules.md` 파일 + `.claude/settings.json`의 `fusion.firmware: true` 플래그. Hook과 SKILL.md 양쪽 python heredoc에 동일한 firmware 분기를 삽입(코드 복제). base reviewer.md·parse-verdict.sh는 무변경.

**Tech Stack:** bash, python3, `codex` CLI ≥ 0.128.0, `git`, `shasum`. 외부 의존 없음.

**Spec:** `docs/superpowers/specs/2026-05-09-codex-claude-fusion-phase3-design.md` (커밋 96eb087)

---

## File Structure

```
skills/fusion/
├── prompts/
│   ├── reviewer.md                # Phase 1 (재사용, 무변경)
│   └── firmware-rules.md          # Phase 3 신규: 룰셋 본체
└── lib/
    ├── parse-verdict.sh           # Phase 1 (무변경)
    └── auto-review-hook.sh        # Phase 2 (firmware 분기 추가)
SKILL.md                           # Phase 1 (firmware 분기 + PROJECT_ROOT 추가)
enable-firmware.sh                 # Phase 3 신규
disable-firmware.sh                # Phase 3 신규
tests/
├── parse-verdict.test.sh          # Phase 1 (재사용)
├── auto-review-hook.test.sh       # Phase 2 (재사용)
├── settings-merge.test.sh         # Phase 2 (재사용)
└── firmware-mode.test.sh          # Phase 3 신규: prompt 합성 분기 검증
README.md                          # 변경: "펌웨어 모드 (Phase 3)" 섹션
```

각 파일 책임:
- `firmware-rules.md` — Codex에 전달되는 펌웨어 룰셋 텍스트. 슬롯 토큰 사용 금지(slot 치환 이후 append).
- `enable-firmware.sh` — `.claude/settings.json`의 `fusion.firmware`를 `true`로 설정 (Phase 2 enable-auto.sh 패턴).
- `disable-firmware.sh` — `fusion.firmware` 키 제거, 빈 객체 자동 정리.
- `firmware-mode.test.sh` — hook이 prompt 합성 시 firmware section을 조건부 append하는지 검증.

---

### Task 1: `firmware-rules.md` 작성

**Files:**
- Create: `skills/fusion/prompts/firmware-rules.md`

- [ ] **Step 1: 파일 작성**

`skills/fusion/prompts/firmware-rules.md` 파일 전체 내용 (정확히 그대로):

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

- [ ] **Step 2: 슬롯 토큰 부재 검증**

Run: `grep -c '{{[A-Z_]\+}}' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/firmware-rules.md`
Expected: `0` (slot 토큰 없음)

- [ ] **Step 3: 파일 길이 sanity**

Run: `wc -l /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/prompts/firmware-rules.md`
Expected: 30~45줄 (스펙 §5 규모와 일치)

- [ ] **Step 4: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add skills/fusion/prompts/firmware-rules.md
git commit -m "feat: 펌웨어 특화 룰셋 (firmware-rules.md) 추가

ISR safety + race conditions(A) + Volatile correctness(B) 두
카테고리. 각 룰에 BLOCKER/MAJOR/MINOR 매핑 명시. (A.ISR)/(B.VOL)
prefix로 펌웨어 이슈 식별. 슬롯 토큰 사용 금지 (slot 치환 후
append되므로). DMA·Watchdog·Static memory는 Phase 3.x로 미룸."
```

---

### Task 2: hook에 firmware 분기 + 단위 테스트 (TDD)

**Files:**
- Modify: `skills/fusion/lib/auto-review-hook.sh`
- Create: `tests/firmware-mode.test.sh`

테스트는 hook을 실제로 실행하고 `/tmp/fusion-*/round-1-prompt.txt`에서 firmware section 포함 여부를 검사.

- [ ] **Step 1: 실패 테스트 작성**

`tests/firmware-mode.test.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Test runner for firmware-mode prompt assembly branch in auto-review-hook.sh.
# Each case sets up a tmp git repo with controlled .claude/settings.json,
# runs the hook with stub codex, then inspects the assembled prompt file
# under /tmp/fusion-<ts>-<rand>/round-1-prompt.txt for the firmware section.

set -u
HOOK="$(cd "$(dirname "$0")"/.. && pwd)/skills/fusion/lib/auto-review-hook.sh"
GIT_BIN_DIR="$(dirname "$(command -v git)")"
PASS=0; FAIL=0

mktmprepo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    # add a non-block .c file change so the hook reaches prompt assembly
    printf 'int main(void){return 0;}\n' >> "$d/foo.c"
    git -C "$d" add foo.c
    git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
    printf 'extra1\nextra2\nextra3\nextra4\n' >> "$d/foo.c"
    printf '%s' "$d"
}

stub_codex_dir() {
    local d
    d=$(mktemp -d)
    cat > "$d/codex" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
printf 'Overview: ok.\n\nNo actionable issues.\n\nVERDICT: APPROVED' > "$out"
exit 0
STUB
    chmod +x "$d/codex"
    printf '%s' "$d"
}

# Find the most recent /tmp/fusion-* directory created after a marker time.
# Args: <marker_unix_seconds> → prints the path or empty.
latest_fusion_dir_since() {
    local marker="$1"
    local d
    for d in $(ls -td /tmp/fusion-* 2>/dev/null); do
        # extract timestamp portion (after "fusion-", before "-")
        local ts="${d##*/fusion-}"
        ts="${ts%%-*}"
        if [[ "$ts" -ge "$marker" ]]; then
            printf '%s' "$d"
            return 0
        fi
    done
    printf ''
}

run_hook_and_get_prompt() {
    # Args: <repo> <stub>
    # Returns prompt-file path on stdout, or empty if not produced.
    local repo="$1" stub="$2"
    local marker
    marker=$(date +%s)
    sleep 1
    env -i HOME="$HOME" PATH="$stub:$GIT_BIN_DIR:/usr/bin:/bin" \
        bash -c "cd '$repo' && bash '$HOOK'" >/dev/null 2>&1 || true
    local fdir
    fdir=$(latest_fusion_dir_since "$marker")
    [[ -n "$fdir" && -f "$fdir/round-1-prompt.txt" ]] && printf '%s/round-1-prompt.txt' "$fdir"
}

assert_prompt_contains() {
    local desc="$1" prompt_file="$2" needle="$3"
    if [[ -z "$prompt_file" ]]; then
        FAIL=$((FAIL+1)); printf '  FAIL: %s (no prompt file produced)\n' "$desc"
        return
    fi
    if grep -q "$needle" "$prompt_file"; then
        PASS=$((PASS+1)); printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1)); printf '  FAIL: %s (needle %q missing from %s)\n' "$desc" "$needle" "$prompt_file"
    fi
}

assert_prompt_not_contains() {
    local desc="$1" prompt_file="$2" needle="$3"
    if [[ -z "$prompt_file" ]]; then
        FAIL=$((FAIL+1)); printf '  FAIL: %s (no prompt file produced)\n' "$desc"
        return
    fi
    if grep -q "$needle" "$prompt_file"; then
        FAIL=$((FAIL+1)); printf '  FAIL: %s (needle %q present in %s but should not be)\n' "$desc" "$needle" "$prompt_file"
    else
        PASS=$((PASS+1)); printf '  PASS: %s\n' "$desc"
    fi
}

t_stub=$(stub_codex_dir)
NEEDLE='FIRMWARE-SPECIFIC REVIEW RULES'

# (1) firmware:true → prompt contains firmware section
r1=$(mktmprepo)
mkdir -p "$r1/.claude"
cat > "$r1/.claude/settings.json" <<'JSON'
{"fusion": {"firmware": true}}
JSON
p1=$(run_hook_and_get_prompt "$r1" "$t_stub")
assert_prompt_contains "firmware:true → firmware section in prompt" "$p1" "$NEEDLE"

# (2) firmware:false → prompt does NOT contain firmware section
r2=$(mktmprepo)
mkdir -p "$r2/.claude"
cat > "$r2/.claude/settings.json" <<'JSON'
{"fusion": {"firmware": false}}
JSON
p2=$(run_hook_and_get_prompt "$r2" "$t_stub")
assert_prompt_not_contains "firmware:false → no firmware section" "$p2" "$NEEDLE"

# (3) settings.json absent → prompt does NOT contain firmware section
r3=$(mktmprepo)
p3=$(run_hook_and_get_prompt "$r3" "$t_stub")
assert_prompt_not_contains "settings.json absent → no firmware section" "$p3" "$NEEDLE"

# (4) settings.json corrupt JSON → fallback to base, prompt does NOT contain firmware section
r4=$(mktmprepo)
mkdir -p "$r4/.claude"
printf '{ this is not json' > "$r4/.claude/settings.json"
p4=$(run_hook_and_get_prompt "$r4" "$t_stub")
assert_prompt_not_contains "settings.json corrupt → no firmware section (silent fallback)" "$p4" "$NEEDLE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

권한:
```bash
chmod +x tests/firmware-mode.test.sh
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/firmware-mode.test.sh`
Expected: case (1) FAIL (firmware section이 prompt에 들어가는 분기가 없음). cases (2)(3)(4)는 PASS (firmware section이 없으므로 자연 미포함). 합계 `3 passed, 1 failed`. exit 1.

캡처해서 보고에 포함.

- [ ] **Step 3: hook에 firmware 분기 추가**

`skills/fusion/lib/auto-review-hook.sh`에서 python heredoc 본체 (`PYEOF` 사이의 코드)를 찾아 슬롯 치환 3개 직후에 firmware 분기를 추가.

기존 heredoc 본체:
```python
import sys, os
tmpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])
with open(out_path, "w") as f:
    f.write(s)
```

다음으로 교체 (firmware 분기 + json import 추가):
```python
import sys, os, json
tmpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])

# Phase 3: firmware-mode rules append
project_root = os.environ.get("PROJECT_ROOT", "")
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
if firmware:
    rules_path = os.path.join(os.environ.get("SKILL_DIR", ""), "prompts", "firmware-rules.md")
    if os.path.isfile(rules_path):
        with open(rules_path) as f:
            s += "\n\n" + f.read()

with open(out_path, "w") as f:
    f.write(s)
```

또한 hook의 python 호출 직전에 export를 추가. 현재 hook의 다음 라인을 찾기:
```bash
export TASK_TEXT PREV_HISTORY DIFF_TEXT
python3 - "$SKILL_DIR/prompts/reviewer.md" "$PROMPT_FILE" <<'PYEOF'
```

다음으로 교체:
```bash
export TASK_TEXT PREV_HISTORY DIFF_TEXT PROJECT_ROOT SKILL_DIR
python3 - "$SKILL_DIR/prompts/reviewer.md" "$PROMPT_FILE" <<'PYEOF'
```

(`PROJECT_ROOT`와 `SKILL_DIR`을 export 목록에 추가. 두 변수 모두 hook 상단에서 이미 정의되어 있음.)

- [ ] **Step 4: 통과 확인**

Run: `bash tests/firmware-mode.test.sh`
Expected: 모든 4 케이스 PASS. 합계 `4 passed, 0 failed`. exit 0.

또한 회귀 검증:
```bash
bash tests/auto-review-hook.test.sh
bash tests/settings-merge.test.sh
bash tests/parse-verdict.test.sh
```
Expected: 모두 exit 0 (Phase 1·2 회귀 없음).

캡처해서 보고에 포함.

- [ ] **Step 5: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add skills/fusion/lib/auto-review-hook.sh tests/firmware-mode.test.sh
git commit -m "feat: hook에 firmware mode 분기 + 4 케이스 검증

python heredoc에 settings.json fusion.firmware 검사 분기 추가.
true이면 firmware-rules.md를 reviewer.md 끝에 append. JSON 손상·
부재·false 모두 base mode silent fallback. PROJECT_ROOT, SKILL_DIR
을 python에 export. tests/firmware-mode.test.sh로 prompt 파일을
직접 검사해 4 케이스 검증."
```

---

### Task 3: SKILL.md에 firmware 분기 + `PROJECT_ROOT` 정의·export

**Files:**
- Modify: `skills/fusion/SKILL.md`

SKILL.md는 인라인 명세이므로 hook과 동일한 분기 코드를 복제. SKILL.md는 현재 PROJECT_ROOT를 정의하지 않으므로 추가 필요.

- [ ] **Step 1: SKILL.md 읽기로 위치 확인**

Run: `grep -n 'PYEOF' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/SKILL.md`
Expected: 두 줄 (PYEOF 시작·종료) 출력.

`grep -n '^export TASK_TEXT' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/SKILL.md`
Expected: 한 줄 (export 라인).

`grep -n 'PROJECT_ROOT' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/SKILL.md`
Expected: 빈 출력 (현재 PROJECT_ROOT 미정의).

- [ ] **Step 2: SKILL.md의 §3.a python 합성 직전에 PROJECT_ROOT 추가 + export 갱신**

SKILL.md의 §3.a 내 다음 블록을 찾기:
```bash
export TASK_TEXT PREV_HISTORY DIFF_TEXT
python3 - "$TEMPLATE" "$PROMPT_FILE" <<'PYEOF'
```

다음으로 교체:
```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
export TASK_TEXT PREV_HISTORY DIFF_TEXT PROJECT_ROOT SKILL_DIR
python3 - "$TEMPLATE" "$PROMPT_FILE" <<'PYEOF'
```

(SKILL_DIR은 SKILL.md 상단에서 이미 정의됨.)

- [ ] **Step 3: SKILL.md python heredoc 본체에 firmware 분기 추가**

기존 heredoc 본체 (Task 2에서 hook에 적용한 것과 동일 변경을 SKILL.md에도 적용):

찾기:
```python
import sys, os
tmpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])
with open(out_path, "w") as f:
    f.write(s)
```

교체 (Task 2 Step 3과 동일):
```python
import sys, os, json
tmpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as f:
    s = f.read()
s = s.replace("{{TASK_OR_DIFF_MODE}}", os.environ["TASK_TEXT"])
s = s.replace("{{PREV_HISTORY_OR_EMPTY}}", os.environ["PREV_HISTORY"])
s = s.replace("{{GIT_DIFF_HEAD}}", os.environ["DIFF_TEXT"])

# Phase 3: firmware-mode rules append
project_root = os.environ.get("PROJECT_ROOT", "")
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
if firmware:
    rules_path = os.path.join(os.environ.get("SKILL_DIR", ""), "prompts", "firmware-rules.md")
    if os.path.isfile(rules_path):
        with open(rules_path) as f:
            s += "\n\n" + f.read()

with open(out_path, "w") as f:
    f.write(s)
```

- [ ] **Step 4: 검증**

Run:
```bash
grep -c 'firmware-mode rules append' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/SKILL.md
```
Expected: `1`

Run:
```bash
grep -c 'PROJECT_ROOT=' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/SKILL.md
```
Expected: `1`

Run:
```bash
grep 'export TASK_TEXT.*PROJECT_ROOT.*SKILL_DIR' /Users/jekim/01.Projects/11.CodexClaudeFusion/skills/fusion/SKILL.md
```
Expected: 매칭 (export 라인에 PROJECT_ROOT, SKILL_DIR 포함).

회귀 검증:
```bash
bash tests/firmware-mode.test.sh
bash tests/auto-review-hook.test.sh
bash tests/settings-merge.test.sh
bash tests/parse-verdict.test.sh
```
Expected: 모두 exit 0.

- [ ] **Step 5: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add skills/fusion/SKILL.md
git commit -m "feat: SKILL.md(수동 /fusion)에도 firmware mode 분기 동기화

§3.a 검토자 라운드의 python heredoc에 hook과 동일한 firmware
분기 추가. PROJECT_ROOT를 git rev-parse로 정의하고 export 목록에
PROJECT_ROOT·SKILL_DIR 추가. 코드 복제는 의도적 (helper 분리는
Phase 3.x)."
```

---

### Task 4: `enable-firmware.sh` (settings.json 안전 병합 + 테스트)

**Files:**
- Create: `enable-firmware.sh`
- Modify: `tests/settings-merge.test.sh` (Phase 3 케이스 추가)

- [ ] **Step 1: 실패 테스트 추가**

`tests/settings-merge.test.sh`의 마지막 `printf '\n%s passed, %s failed\n'` 라인 직전에 다음을 삽입:

```bash
# --- Phase 3: enable-firmware.sh cases ---

ENABLE_FW="$REPO/enable-firmware.sh"
DISABLE_FW="$REPO/disable-firmware.sh"

# Setup fresh tmp project for firmware tests
proj_fw=$(mktemp -d)
cd "$proj_fw"
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# (10) enable-firmware on empty project: settings.json gets fusion.firmware=true
bash "$ENABLE_FW" >/dev/null
assert_json_contains "enable-firmware: fusion.firmware=true added" \
    ".claude/settings.json" \
    "d.get('fusion',{}).get('firmware') is True"

# (11) re-enable: idempotent
bash "$ENABLE_FW" >/dev/null
assert_json_contains "enable-firmware: idempotent (still true, no extra)" \
    ".claude/settings.json" \
    "d.get('fusion',{}).get('firmware') is True"

# (12) preserve existing hooks key alongside fusion key
cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "bash /tmp/user-hook.sh"}]}]
  }
}
JSON
bash "$ENABLE_FW" >/dev/null
assert_json_contains "enable-firmware: existing hooks preserved alongside fusion key" \
    ".claude/settings.json" \
    "any('user-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[])) and d.get('fusion',{}).get('firmware') is True"
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: cases (10)(11)(12) FAIL (`enable-firmware.sh` 없음). 합계 `9 passed, 3 failed`. exit 1.

캡처.

- [ ] **Step 3: enable-firmware.sh 작성**

`enable-firmware.sh` 파일 전체 내용 (정확히 그대로):

```bash
#!/usr/bin/env bash
# Enable /fusion firmware mode for the current (or given) project.
# Sets fusion.firmware = true in <project>/.claude/settings.json.
# Backs up settings.json to .bak before edit.

set -euo pipefail

PROJECT="${1:-$PWD}"
SETTINGS="$PROJECT/.claude/settings.json"

mkdir -p "$PROJECT/.claude"

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.bak"
else
    printf '{}' > "$SETTINGS"
fi

if ! python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
fusion = data.setdefault("fusion", {})
already = fusion.get("firmware") is True
fusion["firmware"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("noop" if already else "added")
PYEOF
then
    echo "ERROR: settings.json 손상 — 백업 파일에서 복원하세요: cp \"$SETTINGS.bak\" \"$SETTINGS\"" >&2
    exit 1
fi

echo "Firmware mode enabled in $PROJECT. Rules: ISR/race + Volatile correctness."
```

권한:
```bash
chmod +x enable-firmware.sh
```

- [ ] **Step 4: 통과 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: cases (10)(11)(12) PASS. 합계 `12 passed, 0 failed`. exit 0.

캡처.

- [ ] **Step 5: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add enable-firmware.sh tests/settings-merge.test.sh
git commit -m "feat: enable-firmware.sh 추가

.claude/settings.json의 fusion.firmware를 true로 설정. 기존
hooks 등 다른 키 보존, 중복 방지(idempotent), 기존 파일 .bak
백업, JSON 손상 시 복원 안내. 3개 케이스 검증 (총 12개)."
```

---

### Task 5: `disable-firmware.sh` (정확 제거 + 테스트)

**Files:**
- Create: `disable-firmware.sh`
- Modify: `tests/settings-merge.test.sh` (Phase 3 disable 케이스 추가)

- [ ] **Step 1: 실패 테스트 추가**

`tests/settings-merge.test.sh`의 마지막 `printf '\n%s passed, %s failed\n'` 라인 직전에 다음을 삽입:

```bash
# (13) disable-firmware: removes our key, preserves user's hooks
bash "$DISABLE_FW" >/dev/null
assert_json_contains "disable-firmware: fusion.firmware removed, hooks preserved" \
    ".claude/settings.json" \
    "(d.get('fusion',{}).get('firmware') is None) and any('user-hook.sh' in h.get('command','') for s in d.get('hooks',{}).get('Stop',[]) for h in s.get('hooks',[]))"

# (14) disable-firmware on already-disabled: noop
bash "$DISABLE_FW" >/dev/null
assert_json_contains "disable-firmware: already absent — noop" \
    ".claude/settings.json" \
    "d.get('fusion',{}).get('firmware') is None"

# (15) disable-firmware with no settings.json: graceful
proj_fw3=$(mktemp -d)
cd "$proj_fw3"
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
out=$(bash "$DISABLE_FW" 2>&1) && rc=0 || rc=$?
if [[ "$rc" == "0" ]]; then
    PASS=$((PASS+1)); printf '  PASS: disable-firmware on missing settings.json exits 0\n'
else
    FAIL=$((FAIL+1)); printf '  FAIL: disable-firmware missing settings.json rc=%s out=%q\n' "$rc" "$out"
fi
cd "$proj_fw"
```

- [ ] **Step 2: 실패 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: cases (13)(14)(15) FAIL. 합계 `12 passed, 3 failed`. exit 1.

캡처.

- [ ] **Step 3: disable-firmware.sh 작성**

`disable-firmware.sh` 파일 전체 내용:

```bash
#!/usr/bin/env bash
# Disable /fusion firmware mode for the current (or given) project.
# Removes fusion.firmware from <project>/.claude/settings.json.

set -euo pipefail

PROJECT="${1:-$PWD}"
SETTINGS="$PROJECT/.claude/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
    echo "Firmware mode not enabled (no $SETTINGS)."
    exit 0
fi

cp "$SETTINGS" "$SETTINGS.bak"

if ! python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    text = f.read().strip() or "{}"
data = json.loads(text)
fusion = data.get("fusion", {})
removed = fusion.pop("firmware", None) is not None
if not fusion and "fusion" in data:
    del data["fusion"]
elif fusion:
    data["fusion"] = fusion
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"removed={removed}")
PYEOF
then
    echo "ERROR: settings.json 손상 — 백업 파일에서 복원하세요: cp \"$SETTINGS.bak\" \"$SETTINGS\"" >&2
    exit 1
fi

echo "Firmware mode disabled."
```

권한:
```bash
chmod +x disable-firmware.sh
```

- [ ] **Step 4: 통과 확인**

Run: `bash tests/settings-merge.test.sh`
Expected: 모든 15 케이스 PASS. 합계 `15 passed, 0 failed`. exit 0.

캡처.

- [ ] **Step 5: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add disable-firmware.sh tests/settings-merge.test.sh
git commit -m "feat: disable-firmware.sh 추가

.claude/settings.json에서 fusion.firmware 제거. 빈 fusion 객체
자동 정리, 다른 키(hooks 등) 보존, settings.json 부재 시 graceful
exit 0, JSON 손상 시 복원 안내. 3개 케이스 검증 (총 15개)."
```

---

### Task 6: README "펌웨어 모드 (Phase 3)" 섹션 추가

**Files:**
- Modify: `README.md`

- [ ] **Step 1: README 업데이트**

먼저 README.md를 Read 도구로 읽어 `## 후속 단계 로드맵` 라인 위치를 확인. 그 라인 직전에 다음 새 섹션을 Edit 도구로 삽입:

```
## 펌웨어 모드 (Phase 3)

ARM Cortex-M 펌웨어 코드를 검토할 때 ISR 안전성·race condition·Volatile 정확성 룰을 추가로 적용합니다. 일반 프로젝트 격리를 위해 **project-local opt-in** 방식.

### Project-local opt-in

```bash
cd <your-firmware-project>
/path/to/CodexClaudeFusion/enable-firmware.sh
```

`.claude/settings.json`에 `fusion.firmware: true`가 기록되며, 이후 그 프로젝트의 `/fusion`(수동) 또는 자동 리뷰가 `firmware-rules.md`를 prompt 끝에 append합니다.

해제:
```bash
cd <your-firmware-project>
/path/to/CodexClaudeFusion/disable-firmware.sh
```

### 룰 카테고리 (MVP)

- **A. ISR 안전성 + race condition** — ISR 안 sleep/printf, ISR-shared 변수의 volatile + atomic, memory barrier, critical section 균형
- **B. Volatile 정확성** — 하드웨어 레지스터 volatile, ISR 공유 변수, volatile vs atomic 혼동, `volatile T*` vs `T* volatile`

펌웨어 이슈는 출력에 카테고리 prefix가 붙습니다:
```
BLOCKER (A.ISR): src/foo.c:42 — ...
MAJOR (B.VOL):   src/bar.c:17 — ...
```

DMA·Watchdog·Static memory·자동 감지·사용자 정의 룰은 Phase 3.x로 미룸.

### 검증 시나리오 (dogfooding)

| 시나리오 | 기대 결과 | 결과 |
|---|---|---|
| F1: enable-firmware → ISR 함수에 `printf` 추가 → /fusion | `BLOCKER (A.ISR)` 출력 | (추후 기록) |
| F2: enable-firmware → ISR-shared 변수에 volatile 누락 → /fusion | `MAJOR (B.VOL)` 또는 `MAJOR (A.ISR)` | (추후 기록) |
| F3: disable-firmware → 같은 buggy 코드 → /fusion | base mode (펌웨어 prefix 없음) | (추후 기록) |
| F4: enable-firmware → 일반 .c 변경 (펌웨어 무관) | base + firmware 룰 모두 적용, 위반 없으면 APPROVED | (추후 기록) |

```

- [ ] **Step 2: 검증**

Run:
```bash
grep -c '^## 펌웨어 모드' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
grep -c '^| F[1-4]:' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
grep -c 'enable-firmware.sh' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
grep -c 'disable-firmware.sh' /Users/jekim/01.Projects/11.CodexClaudeFusion/README.md
```
Expected: 1, 4, ≥1, ≥1.

또한 후속 단계 로드맵의 Phase 3 라인 갱신:

찾기:
```
- **Phase 3**: 펌웨어 특화 룰셋 (ARM/embedded, ISR, watchdog)
```

교체:
```
- **Phase 3**: 펌웨어 특화 룰셋 ✅ 구현 진행 중 (ISR/race + Volatile MVP — 위 "펌웨어 모드" 섹션 참조; DMA·Watchdog은 Phase 3.x)
```

- [ ] **Step 3: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add README.md
git commit -m "docs: README에 펌웨어 모드 섹션 추가 + 로드맵 갱신

Phase 3 펌웨어 모드 사용자 가이드. enable·disable-firmware.sh
사용법, 룰 카테고리(A.ISR/race + B.VOL) 안내, 출력 prefix 형식
(BLOCKER (A.ISR)·MAJOR (B.VOL)), F1~F4 dogfooding 시나리오 표
(결과는 추후 기록). 후속 단계 로드맵의 Phase 3 라인을 \"구현
진행 중\"으로 갱신."
```

---

### Task 7: 통합 정적 검증

산출물 없음, 커밋 없음. 모든 검증을 수행하고 결과 캡처.

- [ ] **Step 1: bash 문법 검사**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
bash -n skills/fusion/lib/auto-review-hook.sh \
 && bash -n enable-auto.sh \
 && bash -n disable-auto.sh \
 && bash -n enable-firmware.sh \
 && bash -n disable-firmware.sh \
 && bash -n install.sh \
 && bash -n skills/fusion/lib/parse-verdict.sh \
 && bash -n tests/parse-verdict.test.sh \
 && bash -n tests/auto-review-hook.test.sh \
 && bash -n tests/settings-merge.test.sh \
 && bash -n tests/firmware-mode.test.sh \
 && echo "all syntax OK"
```
Expected: `all syntax OK`.

- [ ] **Step 2: 모든 테스트 재실행**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
echo "=== parse-verdict ==="; bash tests/parse-verdict.test.sh; echo "exit=$?"
echo "=== auto-review-hook ==="; bash tests/auto-review-hook.test.sh; echo "exit=$?"
echo "=== settings-merge ==="; bash tests/settings-merge.test.sh; echo "exit=$?"
echo "=== firmware-mode ==="; bash tests/firmware-mode.test.sh; echo "exit=$?"
```
Expected:
- parse-verdict: `13 passed, 0 failed`, exit 0
- auto-review-hook: `14 passed, 0 failed`, exit 0
- settings-merge: `15 passed, 0 failed`, exit 0
- firmware-mode: `4 passed, 0 failed`, exit 0
- 합계 46/46 PASS.

- [ ] **Step 3: slot 토큰 cross-check (Phase 1·2와 동일)**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
echo "--- reviewer.md slots ---"
grep -o '{{[A-Z_]\+}}' skills/fusion/prompts/reviewer.md | sort -u
echo "--- auto-review-hook.sh slots ---"
grep -o '{{[A-Z_]\+}}' skills/fusion/lib/auto-review-hook.sh | sort -u
echo "--- SKILL.md slots ---"
grep -o '{{[A-Z_]\+}}' skills/fusion/SKILL.md | sort -u
echo "--- firmware-rules.md slots (must be empty) ---"
grep -o '{{[A-Z_]\+}}' skills/fusion/prompts/firmware-rules.md | sort -u
```
Expected: 처음 3개 모두 동일 3개 토큰. firmware-rules.md는 빈 출력.

- [ ] **Step 4: Phase 1·2 무손 확인**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
echo "--- reviewer.md (Phase 1) diff vs Phase 2 final ---"
git diff e9ef5e5 -- skills/fusion/prompts/reviewer.md
echo "--- parse-verdict.sh (Phase 1) diff vs Phase 2 final ---"
git diff e9ef5e5 -- skills/fusion/lib/parse-verdict.sh
```
Expected: 둘 다 빈 출력.

- [ ] **Step 5: PROJECT_ROOT·SKILL_DIR export 정합성**

Run:
```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
grep 'export TASK_TEXT.*PROJECT_ROOT.*SKILL_DIR' skills/fusion/lib/auto-review-hook.sh
grep 'export TASK_TEXT.*PROJECT_ROOT.*SKILL_DIR' skills/fusion/SKILL.md
```
Expected: 두 곳 모두 매칭 (export 라인에 PROJECT_ROOT, SKILL_DIR 포함).

- [ ] **Step 6: 변경 없음 확인**

Run: `git status --short`
Expected: 빈 출력.

이 task는 산출물·커밋 없음.

---

### Task 8: dogfooding F1~F4 (수동, 사용자 주도)

스펙 §9 dogfooding 시나리오. 사용자 환경에서 실제 codex 호출 + Claude Code 세션 필요.

- [ ] **Step 1: 임시 firmware 프로젝트 셋업**

```bash
cd /tmp
rm -rf p3-dogfood
mkdir p3-dogfood && cd p3-dogfood
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
/Users/jekim/01.Projects/11.CodexClaudeFusion/enable-firmware.sh
cat .claude/settings.json
```
Expected: settings.json에 `"fusion": {"firmware": true}`.

- [ ] **Step 2: F1 — ISR 함수에 printf**

```bash
cd /tmp/p3-dogfood
cat > isr.c <<'EOF'
#include <stdio.h>

/* Timer interrupt service routine. */
void TIMER0_IRQHandler(void) {
    printf("tick\n");   /* BUG: printf in ISR — blocking I/O */
}
EOF
git add -N isr.c
SECONDS=0
out=$(bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh 2>&1)
rc=$?
echo "exit=$rc, ${SECONDS}s"
echo "out=[$out]"
```
Expected: 출력에 `BLOCKER (A.ISR)` 또는 `BLOCKER` + ISR/printf 관련 텍스트.

결과를 README의 F1 행에 기록.

- [ ] **Step 3: F2 — ISR-shared 변수 volatile 누락**

```bash
cd /tmp/p3-dogfood
cat > shared.c <<'EOF'
/* Shared between ISR and main loop. */
unsigned int counter = 0;   /* BUG: missing volatile */

void TIMER1_IRQHandler(void) {
    counter++;   /* incremented in ISR */
}

unsigned int get_counter(void) {
    return counter;   /* read in main loop — compiler may optimize the read */
}
EOF
git add -N shared.c
> .fusion-cache.txt   # cache 비워서 재review 트리거
SECONDS=0
out=$(bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh 2>&1)
rc=$?
echo "exit=$rc, ${SECONDS}s"
echo "out=[$out]"
```
Expected: 출력에 `MAJOR (B.VOL)` 또는 `MAJOR (A.ISR)` + volatile 관련 텍스트.

결과를 F2 행에 기록.

- [ ] **Step 4: F3 — disable 후 같은 buggy 코드**

```bash
cd /tmp/p3-dogfood
/Users/jekim/01.Projects/11.CodexClaudeFusion/disable-firmware.sh
> .fusion-cache.txt
SECONDS=0
out=$(bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh 2>&1)
rc=$?
echo "exit=$rc, ${SECONDS}s"
echo "out=[$out]"
```
Expected: REVISE 또는 APPROVED 가능. 어떤 경우든 출력에 `(A.ISR)` 또는 `(B.VOL)` prefix는 등장 *안* 함 (firmware mode off).

결과를 F3 행에 기록.

- [ ] **Step 5: F4 — 일반 .c 변경 (펌웨어 무관)**

```bash
cd /tmp/p3-dogfood
/Users/jekim/01.Projects/11.CodexClaudeFusion/enable-firmware.sh
git add isr.c shared.c
git -c user.email=t@t -c user.name=t commit -q -m "F1+F2 baseline"
cat > util.c <<'EOF'
#include <string.h>

/* Trim trailing whitespace in-place. Returns the new length. */
size_t rtrim(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == ' ' || s[n-1] == '\t' || s[n-1] == '\n')) {
        s[--n] = '\0';
    }
    return n;
}
EOF
git add -N util.c
> .fusion-cache.txt
SECONDS=0
out=$(bash $HOME/.claude/skills/fusion/lib/auto-review-hook.sh 2>&1)
rc=$?
echo "exit=$rc, ${SECONDS}s"
echo "out=[$out]"
```
Expected: 일반 `rtrim` 코드는 펌웨어 위반 없음 → APPROVED 또는 MINOR-only. 출력에 `(A.ISR)`/`(B.VOL)` 없으면 false-positive 없음 확인.

결과를 F4 행에 기록.

- [ ] **Step 6: README 결과 표 갱신**

`README.md`의 F1~F4 표 "결과" 열을 실제 결과로 채움. `(추후 기록)` → 실제 출력 요약.

- [ ] **Step 7: 정리**

```bash
rm -rf /tmp/p3-dogfood
```

- [ ] **Step 8: 커밋**

```bash
cd /Users/jekim/01.Projects/11.CodexClaudeFusion
git add README.md
git commit -m "docs: Phase 3 dogfooding F1~F4 결과 기록

펌웨어 모드 실전 검증. F1(ISR printf), F2(ISR-shared volatile
누락), F3(disable 비교), F4(일반 .c false-positive 검사) 결과를
README 시나리오 표에 채움. Phase 3 인수 기준 충족."
```

---

## Self-Review 체크리스트 (실행자가 모두 마친 뒤 점검)

- [ ] 스펙 §1~§11 각 절이 적어도 한 task로 다뤄졌는가
- [ ] base reviewer.md, parse-verdict.sh가 무변경 (Phase 1 회귀 0)
- [ ] hook과 SKILL.md python heredoc의 firmware 분기가 동일
- [ ] export 라인에 PROJECT_ROOT, SKILL_DIR 둘 다 추가됨 (두 곳)
- [ ] firmware-rules.md에 슬롯 토큰 없음 (slot 치환 후 append이므로)
- [ ] settings.json 손상·부재 silent fallback (firmware=false)
- [ ] enable·disable이 사용자 hooks 등 다른 키 보존
- [ ] 4개 테스트 합계 46 PASS (parse-verdict 13, auto-review-hook 14, settings-merge 15, firmware-mode 4)

---

**Plan 완료.** 저장 위치: `docs/superpowers/plans/2026-05-09-codex-claude-fusion-phase3.md`
