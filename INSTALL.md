# Claude Fusion 설치 가이드

이 문서는 팀원이 Claude Fusion을 설치하고 기본 동작을 확인하기 위한 절차입니다.

## 1. 전제 조건

다음 명령이 동작해야 합니다.

```bash
git --version
python3 --version
claude --version
codex --version
```

역할은 다음과 같습니다.

| 도구 | 용도 |
|---|---|
| Claude Code | `/fusion`, `/fusion-debug` 실행 |
| Codex CLI | Claude Fusion이 read-only reviewer로 호출 |
| Codex companion plugin | Codex 쪽에서 Fusion 상태 진단, Claude read-only review 요청 |

## 2. 처음 설치

도구를 보관할 위치에서 repository를 clone합니다. 프로젝트 repository 안에 clone하지 않는 것을 권장합니다.

```bash
cd ~/01.Projects/11.AI_PlugIn
git clone https://github.com/jekim0109/CodexClaudeFusion.git CodexClaudeFusion
cd CodexClaudeFusion
```

Claude Code용 Fusion skill을 설치합니다.

```bash
./install.sh
```

Codex companion plugin을 등록합니다.

```bash
./install-codex-companion.sh
```

## 3. 이미 설치된 경우 업데이트

이미 clone한 repository가 있으면 최신 버전을 받은 뒤 installer를 다시 실행합니다.

```bash
cd ~/01.Projects/11.AI_PlugIn/CodexClaudeFusion
git pull
./install.sh
./install-codex-companion.sh
```

`install.sh`는 기존 `~/.claude/skills/fusion`과 `~/.claude/skills/fusion-debug`가 symlink이면 새 경로로 갱신합니다. 실제 디렉터리이면 덮어쓰지 않고 멈춥니다.

## 4. 설치 확인

Claude skill symlink를 확인합니다.

```bash
readlink ~/.claude/skills/fusion
readlink ~/.claude/skills/fusion-debug
```

Codex companion 등록을 확인합니다.

```bash
grep -n "claude-fusion-companion" ~/.agents/plugins/marketplace.json
```

진단 스크립트를 실행합니다.

```bash
cd ~/01.Projects/11.AI_PlugIn/CodexClaudeFusion
bash plugins/claude-fusion-companion/scripts/diagnose-fusion.sh
```

## 5. 사용 방법

Claude Code에서 주작업을 하고 Codex inspection을 받을 때:

```text
/fusion
/fusion <작업 설명>
/fusion-debug <증상 설명>
```

Codex에서 주작업을 하고 Claude inspection을 받을 때:

```text
fusion-status
fusion-claude-review
```

방향은 다음과 같습니다.

| 현재 agent | 주작업 | Inspector | Entrypoint |
|---|---|---|---|
| Claude Code | Claude | Codex | `/fusion` |
| Claude Code | Claude debugging | Codex | `/fusion-debug` |
| Codex | Codex | Claude | `fusion-claude-review` |

## 6. 프로젝트별 자동 리뷰 켜기

자동 리뷰는 전역 설치가 아니라 프로젝트별 opt-in입니다. 대상 프로젝트 폴더에서 실행합니다.

```bash
cd /path/to/your-project
/path/to/CodexClaudeFusion/enable-auto.sh
```

펌웨어/임베디드 룰이 필요한 프로젝트에서는 추가로 실행합니다.

```bash
/path/to/CodexClaudeFusion/enable-firmware.sh
```

해제:

```bash
/path/to/CodexClaudeFusion/disable-auto.sh
/path/to/CodexClaudeFusion/disable-firmware.sh
```

## 7. 주의 사항

- `./install.sh`는 Claude Code skill만 설치합니다.
- `./install-codex-companion.sh`는 Codex companion plugin만 등록합니다.
- `/fusion`은 Claude Code 안에서 실행됩니다.
- `fusion-claude-review`는 Codex 쪽 companion entrypoint입니다.
- Codex companion만 설치해도 `/fusion`은 생기지 않습니다.
- Claude auth 상태는 sandbox 안에서 false negative가 날 수 있습니다. 재로그인 전에는 터미널에서 직접 `claude auth status`를 확인하세요.

## 8. 문제 해결

Claude에서 `/fusion`이 보이지 않으면:

```bash
readlink ~/.claude/skills/fusion
```

Codex에서 companion이 보이지 않으면:

```bash
cat ~/.agents/plugins/marketplace.json
```

구버전 Codex skill이 남아 혼동되면 백업 이름으로 이동합니다.

```bash
mv ~/.codex/skills/fusion ~/.codex/skills/fusion.legacy-$(date +%Y%m%d)
```

기존 marketplace는 companion installer 실행 시 자동으로 백업됩니다.

```text
~/.agents/plugins/marketplace.json.bak
```
