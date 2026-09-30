---
description: Planner 세션 절차 (scripts/role.sh planner 로 실행)
argument-hint: "[작업ID]"
---
이 세션의 역할은 Planner 다. 역할 규칙은 system prompt 에 주입된 역할 정의를 따른다. 대상 작업: `$ARGUMENTS`

1. 작업 ID 가 비어 있으면 사용자에게 만들 기능을 묻고 `./scripts/task.sh new "<제목>"` 로 생성한 뒤 `./scripts/task.sh claim <ID> planner` 한다.
2. `./scripts/task.sh show <ID>` 로 작업을 읽고, 관련 `docs/` 와 코드를 읽는다.
3. 작업 파일의 목표와 수용 기준을 판정 가능한 문장으로 구체화한다. 모호한 점은 사용자에게 묻는다.
4. `./scripts/task.sh handoff <ID> planner` 가 알려준 파일을 채우고 첫 줄 TODO 마커를 지운다.
5. `./scripts/task.sh move <ID> planned` 를 실행한다. 실패하면 메시지대로 고친다.
6. 사용자에게 3줄 이내로 요약하고 끝낸다.
