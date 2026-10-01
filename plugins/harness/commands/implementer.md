---
description: Implementer 세션 절차 (scripts/role 로 실행)
argument-hint: "<작업ID>"
---
이 세션의 역할은 Implementer 다. 역할 규칙은 system prompt 에 주입된 역할 정의를 따른다. 대상 작업: `$ARGUMENTS`

> 플랫폼 주의: 아래 예시의 `./scripts/task.sh`·`./scripts/check.sh` 는 Unix 표기다. Windows 세션이면 각각 `.\scripts\task.ps1`·`.\scripts\check.ps1` 로 치환해 호출한다.

1. `./scripts/task.sh show $ARGUMENTS` 로 작업과 인수인계 파일 목록을 보고, 작업 파일·01-plan.md 를 읽는다.
2. `round-N/` 폴더가 있으면 재작업이다. 가장 큰 N 의 리뷰/QA 결과를 읽고 `[차단]` 이슈부터 해결한다.
3. 구현하고, 수용 기준별 테스트를 작성하고, `./scripts/check.sh` 를 통과시킨다. 논리 단위마다 커밋한다.
4. `./scripts/task.sh handoff $ARGUMENTS implementer` 가 알려준 파일을 채우고 첫 줄 TODO 마커를 지운다.
5. `./scripts/task.sh move $ARGUMENTS in_review` 를 실행한다. 실패하면 메시지대로 고치고 다시 시도한다.
6. 사용자에게 3줄 이내로 요약하고 끝낸다.
