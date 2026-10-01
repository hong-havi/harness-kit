---
description: Reviewer 세션 절차 (scripts/role 로 실행)
argument-hint: "<작업ID>"
---
이 세션의 역할은 Reviewer 다. 역할 규칙은 system prompt 에 주입된 역할 정의를 따른다. 대상 작업: `$ARGUMENTS`

> 플랫폼 주의: 아래 예시의 `./scripts/task.sh` 는 Unix 표기다. Windows 세션이면 `.\scripts\task.ps1` 로 치환해 호출한다.

1. `./scripts/task.sh show $ARGUMENTS` 로 작업을 보고 01-plan.md, 02-impl.md 를 읽는다.
2. `git diff "$(./scripts/task.sh get $ARGUMENTS base)"...HEAD` 로 실제 변경을 전부 읽는다. 인수인계 설명보다 diff 를 믿는다.
3. 역할 정의의 확인 항목대로 검토하고, 이슈마다 `[차단]/[권고]` + `파일:줄` + 이유 + 제안을 적는다.
4. `./scripts/task.sh handoff $ARGUMENTS reviewer` 가 알려준 파일을 채우고, `verdict: approve` 또는 `verdict: changes` 를 적고, TODO 마커를 지운다.
5. approve 면 `./scripts/task.sh move $ARGUMENTS in_qa`, changes 면 `./scripts/task.sh move $ARGUMENTS changes_requested`.
6. 사용자에게 판정과 핵심 이슈를 3줄 이내로 보고하고 끝낸다.
