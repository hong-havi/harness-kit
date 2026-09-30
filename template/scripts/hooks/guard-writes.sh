#!/usr/bin/env bash
# PreToolUse 훅: 역할별 파일 쓰기 범위를 강제한다.
# HARNESS_ROLE 이 없으면(사람이 직접 연 세션) 아무것도 막지 않는다.
# 한계: Bash 명령을 통한 파일 쓰기는 여기서 막지 못한다.
set -uo pipefail
ROLE="${HARNESS_ROLE:-}"
[ -z "$ROLE" ] && exit 0

input="$(cat)"
path="$(printf '%s' "$input" | grep -oE '"(file_path|notebook_path)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
  sed -E 's/.*:[[:space:]]*"(.*)"$/\1/')"
[ -z "$path" ] && exit 0

norm() { # 존재하는 가장 가까운 상위 디렉터리 기준으로 심볼릭 링크 해석
  local p="$1" d
  d="$(dirname "$p")"
  while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  echo "$(cd "$d" && pwd -P)${p#"$d"}"
}
PROJ="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" && pwd -P)"
MAIN="$(cd "${HARNESS_MAIN:-$PROJ}" && pwd -P)"
case "$path" in /*) ;; *) path="$PROJ/$path" ;; esac
P="$(norm "$path")"

block() { echo "[$ROLE] 쓰기 차단: $P — $1" >&2; exit 2; }
under() { case "$P" in "$1"/*) return 0 ;; *) return 1 ;; esac; }

# 하네스 자체는 사람만 수정
for root in "$MAIN" "$PROJ"; do
  for h in .claude roles scripts/hooks scripts/task.sh scripts/role.sh scripts/check.sh scripts/check.conf work/templates; do
    if [ "$P" = "$root/$h" ] || under "$root/$h"; then
      block "하네스 파일은 사람만 수정합니다. 필요하면 인수인계의 '하네스 개선 제안'에 적으세요"
    fi
  done
done

under "$MAIN/work/handoffs" && exit 0
if under "$MAIN/work/tasks"; then
  [ "$ROLE" = planner ] && exit 0
  block "작업 파일은 planner 만 편집하며, 상태 변경은 ./scripts/task.sh 로 합니다"
fi

case "$ROLE" in
  planner)
    under "$MAIN/docs" && exit 0
    block "planner 는 docs/ 와 work/ 만 수정합니다. 코드는 implementer 몫입니다" ;;
  implementer)
    under "$PROJ/work" && block "작업 상태는 메인 체크아웃의 work/ 에만 둡니다"
    under "$PROJ" && exit 0
    block "현재 worktree($PROJ) 밖은 수정할 수 없습니다" ;;
  reviewer|qa)
    block "$ROLE 는 인수인계 파일(work/handoffs/)만 작성합니다. 수정 사항은 지적으로 남기세요" ;;
esac
exit 0
