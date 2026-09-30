# harness-kit

역할 기반 세션(Planner → Implementer → Reviewer → QA)으로 Claude Code 프로젝트를 운영하기 위한 키트.
하나의 저장소에 두 가지가 들어 있다.

| 구성 | 위치 | 역할 | 갱신 방식 |
|---|---|---|---|
| copier 템플릿 | `copier.yml`, `template/` | 프로젝트마다 들어가는 파일 (역할 정의, 상태 머신, 훅, 문서 뼈대) | `copier update` |
| Claude Code 플러그인 | `plugins/harness/` | 역할별 작업 절차 커맨드 (`/harness:planner` 등) | `/plugin update` |

## 1. 최초 1회: 키트 저장소 만들기

```bash
cd harness-kit
# marketplace.json, plugin.json 의 YOUR_NAME 수정
git init && git add -A && git commit -m "harness-kit v0.1.0" && git tag v0.1.0
git remote add origin git@github.com:<계정>/harness-kit.git && git push -u origin main --tags
pip install copier   # 또는 uv tool install copier / pipx install copier
```

> **Windows / `copier: command not found`**
> `pip install --user copier` 로 설치했을 때 실행파일 경로가 PATH 에 없을 수 있다. 두 가지 중 하나:
> - 그대로 `python -m copier ...` 로 호출 (아래 예시의 `copier` 를 `python -m copier` 로 바꿔 쓴다).
> - 또는 PATH 에 Python `Scripts` 디렉터리를 추가. Windows Store Python 3.13 기준 예:
>   `C:\Users\<사용자>\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\Scripts`
>   (`python -m site --user-site` 로 위치 확인 후 `..\Scripts` 를 잡으면 된다.)

Claude Code 에서 플러그인 설치 (한 번만):
```
/plugin marketplace add <계정>/harness-kit
/plugin install harness@harness-kit
```

## 2. 새 프로젝트 시작

```bash
copier copy gh:<계정>/harness-kit my-project   # 스택, 검증 명령을 물어봄
cd my-project
git init && git add -A && git commit -m "init harness"   # worktree 가 하네스 파일을 갖도록 반드시 커밋
./scripts/check.sh                                      # 검증 명령 동작 확인
```

기존 프로젝트에 적용할 때도 같은 명령을 프로젝트 폴더에 실행하면 된다 (충돌 파일은 copier 가 물어본다).

## 3. 일하는 흐름

```
todo ─[planner]→ planned ─[implementer]→ in_review ─[reviewer]→ in_qa ─[qa]→ done
                    ↑                         │                    │
                    └────── changes_requested ←────────────────────┘
```

각 역할은 **별도 터미널에서** 실행한다. 작업 ID 를 생략하면 그 역할의 다음 작업을 자동으로 집는다.

```bash
./scripts/role.sh planner              # 메인 체크아웃에서 실행, 새 작업 생성·계획
./scripts/role.sh implementer          # ../my-project-T-001 worktree 생성 후 그 안에서 실행
./scripts/role.sh reviewer             # 같은 worktree 에서 읽기 전용으로 실행
./scripts/role.sh qa
./scripts/task.sh list                 # 보드 현황 (Claude 안에서는 /harness:status)
```

`done` 이 되면 스크립트가 출력하는 병합 명령을 사람이 확인하고 실행한다.

`role.sh` 가 해주는 일: 작업 점유(owner) → worktree 준비 → `roles/<역할>.md` 를 system prompt 로 주입 → `HARNESS_ROLE` 설정 → `/harness:<역할> <ID>` 로 세션 시작.
실행 전 확인은 `HARNESS_DRY_RUN=1 ./scripts/role.sh implementer`.

## 4. 강제 장치 (문서가 아니라 코드로)

**상태 전이 게이트** (`scripts/task.sh move`)
- 모든 전이는 해당 역할의 인수인계 파일이 있어야 하고, 템플릿 첫 줄의 TODO 마커가 지워져 있어야 한다.
- `→ in_review`: 커밋되지 않은 변경 없음 + base 대비 커밋 존재 + worktree 에서 `check.sh` 통과.
- 리뷰/QA 는 `verdict:` 값(approve/changes, pass/fail)과 전이 방향이 일치해야 한다.
- 반려 시 이번 라운드의 02~04 파일을 `round-N/` 으로 보관하므로, 다음 라운드는 새로 써야 통과한다.

**쓰기 가드** (`scripts/hooks/guard-writes.sh`, PreToolUse)

| 역할 | 쓸 수 있는 곳 |
|---|---|
| planner | `docs/`, `work/` (작업 파일 포함) |
| implementer | 자기 worktree 코드, `work/handoffs/` |
| reviewer, qa | `work/handoffs/` 만 |
| 공통 금지 | `.claude/`, `roles/`, `scripts/{hooks,task.sh,role.sh,check.sh,check.conf}`, `work/templates/` |

`HARNESS_ROLE` 이 없는 세션(사람이 그냥 `claude` 를 연 경우)은 막지 않는다.

**종료 게이트** (`scripts/hooks/stop-gate.sh`, Stop): implementer 세션에 코드 변경이 있으면 `check.sh` 통과 전까지 종료를 한 번 막는다. 무한 루프 방지를 위해 두 번째부터는 통과시키며, 최종 방어선은 전이 게이트다.

## 5. 커스터마이즈

- 검증 명령: `scripts/check.conf`
- 역할 행동: `roles/*.md` (프로젝트별로 조정 가능, 범용 개선은 키트의 `template/roles/` 로 올리기)
- 작업 절차: `plugins/harness/commands/*.md` (모든 프로젝트 공통)
- 설계/규칙: `docs/`. 리뷰에서 반복 지적되는 규칙은 린트 규칙이나 테스트로 옮기는 것을 권장.

## 6. 하네스 개선 반영

키트 저장소를 고친 뒤 새 태그를 붙이면:
```bash
cd my-project && copier update          # 템플릿 변경분을 3-way merge 로 반영
```
플러그인은 Claude Code 에서 `/plugin marketplace update harness-kit`.

## 알려진 한계

- 쓰기 가드는 Edit/Write 계열 도구만 검사한다. Bash 로 파일을 쓰는 것은 막지 못한다. 필요하면 PreToolUse 에 Bash 검사를 추가하거나 역할별 권한 설정을 더 좁힌다.
- `work/` 는 항상 메인 체크아웃에서만 변경된다(worktree 에서 실행해도 task.sh 가 메인을 찾아감). 작업 브랜치는 `work/` 를 건드리지 않으므로 병합 충돌이 없다. `work/` 변경분은 메인에서 주기적으로 커밋한다.
- 요구 도구: bash, git 2.31+, Claude Code CLI. macOS/Linux 기준 (Windows 는 WSL).
