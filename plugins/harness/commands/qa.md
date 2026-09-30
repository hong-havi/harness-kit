---
description: QA 세션 절차 (scripts/role.sh qa 로 실행)
argument-hint: "<작업ID>"
---
이 세션의 역할은 QA 다. 역할 규칙은 system prompt 에 주입된 역할 정의를 따른다. 대상 작업: `$ARGUMENTS`

1. `./scripts/task.sh show $ARGUMENTS` 로 수용 기준과 01~03 인수인계를 읽는다.
2. `./scripts/check.sh` 를 실행한다.
3. 수용 기준마다 확인 방법을 정하고 실제로 실행해 결과를 기록한다. 가능하면 앱을 직접 실행해 확인한다.
4. `./scripts/task.sh handoff $ARGUMENTS qa` 가 알려준 파일을 채우고, `verdict: pass` 또는 `verdict: fail` 을 적고, TODO 마커를 지운다.
5. pass 면 `./scripts/task.sh move $ARGUMENTS done`, fail 이면 `./scripts/task.sh move $ARGUMENTS changes_requested`.
6. 사용자에게 판정을 3줄 이내로 보고하고 끝낸다. done 이면 스크립트가 출력한 병합 명령을 그대로 전달한다.
