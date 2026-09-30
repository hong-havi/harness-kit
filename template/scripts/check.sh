#!/usr/bin/env bash
# 이 프로젝트의 단일 검증 진입점. 에이전트, Stop 훅, task.sh 게이트가 모두 이것을 호출한다.
# 명령은 scripts/check.conf 에서 설정한다.
set -uo pipefail
cd "$(dirname "$0")/.."

LINT_CMD=""; TYPECHECK_CMD=""; TEST_CMD=""
# shellcheck source=/dev/null
. ./scripts/check.conf

fail=0
ran=0
run() {
  local name="$1" cmd="$2"
  [ -z "$cmd" ] && return 0
  ran=$((ran + 1))
  echo "▶ $name: $cmd"
  if ! bash -c "$cmd"; then
    echo "✗ $name 실패"
    fail=1
  fi
}

run lint "$LINT_CMD"
run typecheck "$TYPECHECK_CMD"
run test "$TEST_CMD"

if [ "$ran" -eq 0 ]; then
  echo "✗ 검증 명령이 하나도 설정되지 않았습니다. scripts/check.conf 를 설정하세요."
  exit 1
fi
[ "$fail" -eq 0 ] && echo "✓ check 통과"
exit "$fail"
