#!/usr/bin/env bash
# 역할 세션 실행기: 작업 점유 → worktree 준비 → 역할 주입 → Claude Code 실행
# 사용: ./scripts/role.sh <planner|implementer|reviewer|qa> [작업ID]
#   작업ID 생략 시 해당 역할의 다음 작업을 자동 선택 (planner 는 없어도 실행)
#   HARNESS_DRY_RUN=1  → 아무것도 바꾸지 않고 실행할 명령만 출력
set -euo pipefail

ROLE="${1:-}"; ID="${2:-}"
MAIN="$(cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)"
TASK="$MAIN/scripts/task.sh"
DRY="${HARNESS_DRY_RUN:-}"
die() { echo "✗ $*" >&2; exit 1; }

case "$ROLE" in planner|implementer|reviewer|qa) ;; *) die "사용법: role.sh <planner|implementer|reviewer|qa> [작업ID]" ;; esac
ROLE_FILE="$MAIN/roles/$ROLE.md"
[ -f "$ROLE_FILE" ] || die "역할 정의 없음: $ROLE_FILE"
command -v claude >/dev/null || [ -n "$DRY" ] || die "claude CLI 를 찾을 수 없습니다"

if [ -z "$ID" ]; then
  ID="$("$TASK" next "$ROLE" 2>/dev/null || true)"
  [ -n "$ID" ] || [ "$ROLE" = planner ] || die "$ROLE 가 처리할 작업이 없습니다 ('task.sh list' 로 확인)"
fi

DIR="$MAIN"
if [ "$ROLE" != planner ]; then
  BRANCH="$("$TASK" get "$ID" branch)"; BASE="$("$TASK" get "$ID" base)"
  WT="$("$TASK" worktree "$ID")"
  if [ -z "$WT" ]; then
    [ "$ROLE" = implementer ] || die "$ID 의 worktree 가 없습니다. implementer 단계가 먼저 필요합니다"
    WT="$(dirname "$MAIN")/$(basename "$MAIN")-$ID"
    if [ -n "$DRY" ]; then
      echo "[dry-run] git worktree add $WT ($BRANCH, base: $BASE)"
    elif git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$MAIN" worktree add "$WT" "$BRANCH"
    else
      git -C "$MAIN" worktree add -b "$BRANCH" "$WT" "$BASE"
    fi
  fi
  DIR="$WT"
fi

if [ -n "$ID" ]; then
  if [ -n "$DRY" ]; then echo "[dry-run] task.sh claim $ID $ROLE"; else "$TASK" claim "$ID" "$ROLE"; fi
fi

export HARNESS_ROLE="$ROLE" HARNESS_TASK="$ID" HARNESS_MAIN="$MAIN"
args=(--append-system-prompt "$(cat "$ROLE_FILE")")
[ "$DIR" != "$MAIN" ] && args+=(--add-dir "$MAIN/work")
args+=("/harness:$ROLE $ID")

if [ -n "$DRY" ]; then
  echo "[dry-run] cd $DIR"
  echo "[dry-run] HARNESS_ROLE=$ROLE HARNESS_TASK=$ID claude --append-system-prompt <roles/$ROLE.md> ${args[*]:2}"
  exit 0
fi
cd "$DIR"
exec claude "${args[@]}"
