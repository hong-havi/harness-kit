#!/usr/bin/env bash
# 작업 상태 관리. 상태 전이는 반드시 이 스크립트로만 한다 (게이트가 여기 있다).
# 어느 worktree 에서 실행해도 항상 메인 체크아웃의 work/ 를 다룬다.
set -euo pipefail

MAIN="$(cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)"
WORK="$MAIN/work"
TASKS="$WORK/tasks"
HANDOFFS="$WORK/handoffs"
TPL="$WORK/templates"
MARKER="TODO: 작성을 마치면"

die() { echo "✗ $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
사용법: task.sh <명령> [인자]
  new <제목>                 새 작업 생성 (todo)
  list [상태]                작업 목록
  next <역할>                역할이 처리할 다음 작업 ID 출력
  claim <ID> <역할>          작업 점유
  release <ID>               점유 해제
  show <ID>                  작업 내용과 관련 파일 경로
  get <ID> <필드>            frontmatter 필드 값
  handoff <ID> <역할>        인수인계 파일 생성(없으면) 후 경로 출력
  worktree <ID>              작업 worktree 경로 출력
  move <ID> <상태>           상태 전이 (게이트 검사)
상태 흐름: todo → planned → in_review → in_qa → done  (리뷰/QA 반려 시 changes_requested)
USAGE
}

fm_get() {
  awk -v k="$2" 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit}
    f{i=index($0,":"); if(substr($0,1,i-1)==k){v=substr($0,i+1);
        sub(/^[ \t]+/,"",v); sub(/[ \t\r]+$/,"",v); print v; exit}}' "$1"
}
fm_set() {
  local tmp; tmp="$(mktemp)"
  awk -v k="$2" -v v="$3" 'NR==1&&$0=="---"{f=1;print;next} f&&$0=="---"{f=0}
    f{i=index($0,":"); if(substr($0,1,i-1)==k){print k": "v; next}} {print}' "$1" > "$tmp" && mv "$tmp" "$1"
}

task_file() { local f="$TASKS/$1.md"; [ -f "$f" ] || die "작업 없음: $1"; echo "$f"; }

role_inputs() {
  case "$1" in
    planner) echo "todo" ;;
    implementer) echo "planned changes_requested" ;;
    reviewer) echo "in_review" ;;
    qa) echo "in_qa" ;;
    *) die "알 수 없는 역할: $1 (planner|implementer|reviewer|qa)" ;;
  esac
}
handoff_name() {
  case "$1" in
    planner) echo "01-plan.md" ;; implementer) echo "02-impl.md" ;;
    reviewer) echo "03-review.md" ;; qa) echo "04-qa.md" ;;
    *) die "알 수 없는 역할: $1" ;;
  esac
}

lock() {
  local i=0
  until mkdir "$WORK/.lock" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 50 ] && die "잠금 획득 실패. 다른 프로세스가 없다면 $WORK/.lock 을 삭제하세요"
    sleep 0.1
  done
  trap 'rmdir "$WORK/.lock" 2>/dev/null || true' EXIT
}

worktree_of() {
  git -C "$MAIN" worktree list --porcelain |
    awk -v b="branch refs/heads/$1" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}'
}

verdict_of() {
  [ -f "$1" ] || return 0
  { grep -E '^verdict:' "$1" || true; } | tail -1 | sed -E 's/^verdict:[[:space:]]*//; s/[[:space:]]*$//'
}

require_done() {
  [ -s "$1" ] || die "인수인계 파일이 없습니다: ${1#"$MAIN"/}  ('task.sh handoff' 로 생성 후 작성)"
  if grep -q "$MARKER" "$1"; then die "인수인계 파일이 작성 중 상태입니다 (첫 줄 TODO 마커 삭제 필요): ${1#"$MAIN"/}"; fi
}

require_verdict() {
  local v; v="$(verdict_of "$1")"
  [ "$v" = "$2" ] || die "${1#"$MAIN"/} 의 verdict 가 '$2' 여야 합니다 (현재: '${v:-없음}')"
}

run_check() {
  local id="$1" f="$2" branch base wt
  branch="$(fm_get "$f" branch)"; base="$(fm_get "$f" base)"
  wt="$(worktree_of "$branch")"
  [ -n "$wt" ] || die "브랜치 $branch 의 worktree 가 없습니다"
  [ -z "$(git -C "$wt" status --porcelain -- . ':!work')" ] || die "커밋되지 않은 변경이 있습니다 ($wt). 커밋 후 다시 시도하세요"
  [ "$(git -C "$MAIN" rev-list --count "$base..$branch")" -gt 0 ] || die "$branch 에 $base 대비 커밋이 없습니다"
  echo "▶ $wt 에서 check.sh 실행"
  (cd "$wt" && ./scripts/check.sh) || die "check.sh 실패. 통과시킨 뒤 다시 시도하세요"
}

archive_round() {
  local h="$HANDOFFS/$1" n
  n="$(find "$h" -maxdepth 1 -type d -name 'round-*' | wc -l | tr -d ' ')"
  n=$((n + 1))
  mkdir -p "$h/round-$n"
  for x in 02-impl.md 03-review.md 04-qa.md; do [ -f "$h/$x" ] && mv "$h/$x" "$h/round-$n/"; done
  echo "  이번 라운드 기록 보관: work/handoffs/$1/round-$n/"
}

cmd_new() {
  local title="$*" n id base esc
  [ -n "$title" ] || die "사용법: task.sh new <제목>"
  mkdir -p "$TASKS"; lock
  n="$(ls "$TASKS" | sed -nE 's/^T-([0-9]+)\.md$/\1/p' | sort -n | tail -1)"
  n=$((10#${n:-0} + 1)); id="$(printf 'T-%03d' "$n")"
  base="$(git -C "$MAIN" symbolic-ref --short HEAD 2>/dev/null || echo main)"
  esc="$(printf '%s' "$title" | sed -e 's/[\\&|]/\\&/g')"
  sed -e "s|{ID}|$id|g" -e "s|{TITLE}|$esc|g" -e "s|{BASE}|$base|g" -e "s|{DATE}|$(date +%Y-%m-%d)|g" \
    "$TPL/task.md" > "$TASKS/$id.md"
  echo "$id"
}

cmd_list() {
  local f s
  printf '%-7s %-18s %-12s %s\n' ID STATUS OWNER TITLE
  for f in "$TASKS"/T-*.md; do
    [ -e "$f" ] || continue
    s="$(fm_get "$f" status)"
    [ -n "${1:-}" ] && [ "$s" != "$1" ] && continue
    printf '%-7s %-18s %-12s %s\n' "$(fm_get "$f" id)" "$s" "$(fm_get "$f" owner)" "$(fm_get "$f" title)"
  done
}

cmd_next() {
  local inputs f s st
  inputs="$(role_inputs "${1:?역할 필요}")"
  for st in $inputs; do
    for f in "$TASKS"/T-*.md; do
      [ -e "$f" ] || continue
      s="$(fm_get "$f" status)"
      if [ "$s" = "$st" ] && [ -z "$(fm_get "$f" owner)" ]; then fm_get "$f" id; return 0; fi
    done
  done
  echo "$1 가 처리할 작업이 없습니다" >&2; return 1
}

cmd_claim() {
  local id="${1:?ID 필요}" role="${2:?역할 필요}" f s owner
  f="$(task_file "$id")"; lock
  s="$(fm_get "$f" status)"; owner="$(fm_get "$f" owner)"
  case " $(role_inputs "$role") " in *" $s "*) ;; *) die "$id 는 $s 상태라 $role 가 맡을 수 없습니다" ;; esac
  [ -z "$owner" ] || [ "$owner" = "$role" ] || die "$id 는 이미 $owner 가 점유 중입니다"
  fm_set "$f" owner "$role"
  echo "✓ $id 점유: $role"
}

cmd_release() { local f; f="$(task_file "${1:?ID 필요}")"; fm_set "$f" owner ""; echo "✓ $1 점유 해제"; }

cmd_show() {
  local id="${1:?ID 필요}" f h wt
  f="$(task_file "$id")"; h="$HANDOFFS/$id"
  cat "$f"
  echo; echo "── 경로 ──"
  echo "작업 파일 : $f"
  echo "인수인계  : $h/"
  if [ -d "$h" ]; then (cd "$h" && find . -type f -name '*.md' | sort | sed 's|^\./|    |'); fi
  wt="$(worktree_of "$(fm_get "$f" branch)")"
  echo "worktree  : ${wt:-(없음)}"
}

cmd_get() { local f; f="$(task_file "${1:?ID 필요}")"; fm_get "$f" "${2:?필드 필요}"; }

cmd_handoff() {
  local id="${1:?ID 필요}" role="${2:?역할 필요}" p
  task_file "$id" >/dev/null
  p="$HANDOFFS/$id/$(handoff_name "$role")"
  mkdir -p "$(dirname "$p")"
  [ -f "$p" ] || sed -e "s|{ID}|$id|g" -e "s|{ROLE}|$role|g" "$TPL/handoff.md" > "$p"
  echo "$p"
}

cmd_worktree() { local f; f="$(task_file "${1:?ID 필요}")"; worktree_of "$(fm_get "$f" branch)"; }

cmd_move() {
  local id="${1:?ID 필요}" to="${2:?상태 필요}" f from h wt branch
  f="$(task_file "$id")"; from="$(fm_get "$f" status)"; h="$HANDOFFS/$id"
  case "$from>$to" in
    "todo>planned")
      require_done "$h/01-plan.md"
      [ -z "$(git -C "$MAIN" status --porcelain -- docs 2>/dev/null)" ] || \
        die "docs/ 에 커밋되지 않은 변경이 있습니다. implementer worktree 는 base 브랜치에서 갈라지므로 planner 의 docs/ 변경은 planned 로 넘기기 전에 커밋해야 반영됩니다" ;;
    "planned>in_review" | "changes_requested>in_review")
      require_done "$h/02-impl.md"; run_check "$id" "$f" ;;
    "in_review>in_qa")
      require_done "$h/03-review.md"; require_verdict "$h/03-review.md" approve ;;
    "in_review>changes_requested")
      require_done "$h/03-review.md"; require_verdict "$h/03-review.md" changes ;;
    "in_qa>done")
      require_done "$h/04-qa.md"; require_verdict "$h/04-qa.md" pass ;;
    "in_qa>changes_requested")
      require_done "$h/04-qa.md"; require_verdict "$h/04-qa.md" fail ;;
    *) die "허용되지 않은 전이: $from → $to" ;;
  esac
  lock
  [ "$to" = "changes_requested" ] && archive_round "$id"
  fm_set "$f" status "$to"; fm_set "$f" owner ""
  echo "✓ $id: $from → $to"
  if [ "$to" = "done" ]; then
    branch="$(fm_get "$f" branch)"; wt="$(worktree_of "$branch")"
    echo "  병합은 사람이 확인 후 진행하세요:"
    echo "    git -C \"$MAIN\" merge --no-ff $branch"
    [ -n "$wt" ] && echo "    git -C \"$MAIN\" worktree remove \"$wt\" && git -C \"$MAIN\" branch -d $branch"
  fi
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new) cmd_new "$@" ;; list) cmd_list "$@" ;; next) cmd_next "$@" ;;
  claim) cmd_claim "$@" ;; release) cmd_release "$@" ;; show) cmd_show "$@" ;;
  get) cmd_get "$@" ;; handoff) cmd_handoff "$@" ;; worktree) cmd_worktree "$@" ;;
  move) cmd_move "$@" ;; ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
