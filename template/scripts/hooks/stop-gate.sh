#!/usr/bin/env bash
# Stop 훅: 코드 변경이 있으면 check.sh 를 통과해야 세션을 끝낼 수 있다.
# 한 번 차단된 뒤(stop_hook_active)에는 무한 루프 방지를 위해 통과시킨다.
# 최종 방어선은 task.sh move 의 게이트다.
set -uo pipefail
input="$(cat)"
case "${HARNESS_ROLE:-}" in planner|reviewer|qa) exit 0 ;; esac
printf '%s' "$input" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0

cd "${CLAUDE_PROJECT_DIR:-$PWD}" || exit 0
[ -z "$(git status --porcelain -- . ':!work' ':!docs' 2>/dev/null)" ] && exit 0

if ! out="$(./scripts/check.sh 2>&1)"; then
  {
    echo "check.sh 가 실패했습니다. 수정한 뒤 종료하세요:"
    printf '%s\n' "$out" | tail -60
  } >&2
  exit 2
fi
exit 0
