#!/usr/bin/env bash
# The GitHub side of a crew run: per-task PR state, the review loop and waits on issues. Plain gh only; never merges, never closes.
#   bash crew-pr.sh <project> mode                      exit 0 when per-task shipping is on (`ship: per-task` in PLAN.md or CREW_SHIP=per-task)
#   bash crew-pr.sh <project> base                      the branch task PRs go into (CREW_BASE_BRANCH, `base: <branch>` in PLAN.md, origin's default)
#   bash crew-pr.sh <project> diffbase                  what "the crew's change" is diffed against: per-task, the base at init (work
#                                                       arrives as merged commits there); otherwise HEAD (work is uncommitted)
#   bash crew-pr.sh <project> comment <pr> <manager|lane> "<text>"     post a marked comment: [manager] text  or  [lane-<lane>] text
#   bash crew-pr.sh <project> state <pr> [lane]         MERGED | CLOSED | CHANGES (+ the manager's comments) | REVIEW | OPEN | UNKNOWN
#   bash crew-pr.sh <project> wait [--lane <lane>] [--max <secs>] pr:<n> issue:<n> ...   lane side: block until a PR is merged or closed,
#                                                       a PR has a [manager] comment newer than the lane's last reply, or an issue closes
#   bash crew-pr.sh <project> watch [--max <secs>]      manager side: block until an open PR's newest marked comment is from a lane
#   bash crew-pr.sh <project> sync                      conductor: merged PRs -> tasks done, closed #n dependencies, fast-forward the base
# Marker protocol (plain comments: GitHub refuses a review of your own PR, and manager and lanes usually share one account). A marked
# comment counts only when its author is you (the gh account) or the repo's OWNER / MEMBER / COLLABORATOR: its text is fed to a lane
# that runs with every tool approved, so a stranger's "[manager]" comment is ignored.
# wait/watch: exit 0 something happened, 3 timeout, 2 gh failed. env: CREW_PR_POLL=60. --max defaults to 900 s, which stays under
# the lane watchdog's hung-command limit (CREW_TOOL_STALL_SECS=1200): a lane that is still waiting calls it again.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
cmd=${2:-}; shift 2 2>/dev/null
here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; prd="$crew/pr"

base_branch() {
  local b=${CREW_BASE_BRANCH:-} x
  [ -n "$b" ] || b=$(sed -n 's/^base: *\([^ ]*\) *$/\1/p' "$crew/PLAN.md" 2>/dev/null | head -1)
  [ -n "$b" ] || b=$(git -C "$proj" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$b" ] || for x in main master; do git -C "$proj" show-ref --verify -q "refs/remotes/origin/$x" && { b=$x; break; }; done
  echo "${b:-main}"
}
per_task() { [ "${CREW_SHIP:-}" = per-task ] || grep -qiE '^ship: *per-task' "$crew/PLAN.md" 2>/dev/null; }

# argv: lane (empty = any lane), "list" to read a PR list. stdin: gh JSON.
marks='
import json, sys
lane, kind = sys.argv[1], sys.argv[2]
def marked(pr):
    out = []
    for c in pr.get("comments") or []:
        if not (c.get("viewerDidAuthor") or c.get("authorAssociation") in ("OWNER", "MEMBER", "COLLABORATOR")): continue
        body = (c.get("body") or "").lstrip()
        if body.startswith("[manager]"): out.append(("manager", body))
        elif body.startswith("[lane-" + (lane + "]" if lane else "")): out.append(("lane", body))
    return out
d = json.load(sys.stdin)
if kind == "list":
    for pr in d:
        m = marked(pr)
        if m and m[-1][0] == "lane": print("REVIEW-NEEDED", pr["number"], pr.get("url", ""), pr.get("title", ""))
elif d.get("state") != "OPEN": print(d.get("state") or "UNKNOWN")
else:
    m = marked(d)
    if not m: print("OPEN")
    elif m[-1][0] == "lane": print("REVIEW")
    else:
        new = []
        for who, body in reversed(m):
            if who != "manager": break
            new.append(body)
        print("CHANGES"); print("\n\n".join(reversed(new)))
'
pr_state() { # pr [lane]
  local j; j=$(cd "$proj" && gh pr view "$1" --json state,comments 2>/dev/null) || { echo UNKNOWN; return 1; }
  printf '%s' "$j" | python3 -I -c "$marks" "${2:-}" one
}
issue_state() { # number -> OPEN | CLOSED
  local j; j=$(cd "$proj" && gh issue view "$1" --json state 2>/dev/null) || return 1
  printf '%s' "$j" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("state",""))'
}

case "$cmd" in
  mode) per_task ;;
  base) base_branch ;;
  diffbase) s=""; per_task && s=$(cat "$prd/start" 2>/dev/null); echo "${s:-HEAD}" ;;
  comment)
    pr=${1:?pr}; who=${2:?manager|lane}; text=${3:?text}
    [ "$who" = manager ] || who="lane-$who"
    (cd "$proj" && gh pr comment "$pr" --body "[$who] $text") ;;
  state) pr_state "${1:?pr}" "${2:-}" ;;
  wait|watch)
    lane=""; max=900; targets=()
    while [ $# -gt 0 ]; do case "$1" in --lane) lane=$2; shift 2;; --max) max=$2; shift 2;; *) targets+=("$1"); shift;; esac; done
    if [ "$cmd" = wait ]; then
      [ ${#targets[@]} -gt 0 ] || { echo "usage: crew-pr.sh <project> wait [--lane <lane>] [--max <secs>] pr:<n> issue:<n> ..." >&2; exit 2; }
      for x in "${targets[@]}"; do case "$x" in pr:?*|issue:?*) ;; *) echo "bad target '$x' (pr:<n> or issue:<n>)" >&2; exit 2;; esac; done
    fi
    t0=$(date +%s); first=1
    while :; do
      hit=0; ok=0
      if [ "$cmd" = watch ]; then
        if j=$(cd "$proj" && gh pr list --state open --limit 100 --json number,url,title,comments 2>/dev/null); then
          ok=1; r=$(printf '%s' "$j" | python3 -I -c "$marks" "" list); [ -n "$r" ] && { echo "$r"; hit=1; }
        fi
      else
        for x in "${targets[@]}"; do
          n=${x#*:}
          case "$x" in
            pr:*) r=$(pr_state "$n" "$lane") || continue; ok=1
              case "$(printf '%s\n' "$r" | head -1)" in
                MERGED) echo "PR-MERGED $n"; hit=1;;
                CLOSED) echo "PR-CLOSED $n"; hit=1;;
                CHANGES) echo "PR-COMMENT $n"; printf '%s\n' "$r" | tail -n +2; hit=1;;
              esac;;
            issue:*) r=$(issue_state "$n") || continue; ok=1
              case "$r" in CLOSED|MERGED) echo "ISSUE-CLOSED $n"; hit=1;; esac;;
          esac
        done
      fi
      [ "$hit" = 1 ] && exit 0
      # fail loudly when gh never answers (not logged in, wrong number): blocking in silence helps nobody
      [ "$first" = 1 ] && [ "$ok" = 0 ] && { echo "gh could not read any target: check 'gh auth status' and the numbers" >&2; exit 2; }
      first=0
      left=$(( max - ($(date +%s) - t0) )); [ "$left" -le 0 ] && { echo "WAIT-TIMEOUT after ${max}s: nothing new yet; call again"; exit 3; }
      p=${CREW_PR_POLL:-60}; [ "$p" -gt "$left" ] && p=$left; sleep "$p"
    done ;;
  sync)
    mkdir -p "$prd"
    while read -r tid lane; do
      [ -n "$tid" ] || continue
      url=$(cat "$prd/$tid.url" 2>/dev/null)
      [ -n "$url" ] || { echo "WAITING $tid $lane (no PR recorded: run crew-ship.sh task $tid)"; continue; }
      r=$(pr_state "$url" "$lane"); s=$(printf '%s\n' "$r" | head -1)
      case "$s" in
        MERGED) bash "$here/crew-tasks.sh" "$proj" set "$tid" "done"; : > "$prd/needs-ff"; echo "MERGED $tid $lane $url";;
        # back to open, not failed: a failed row would be re-verified by the lane's later turns, where its work no longer exists
        CLOSED) bash "$here/crew-tasks.sh" "$proj" set "$tid" open; mv -f "$prd/$tid.url" "$prd/$tid.closed-url"; rm -f "${prd:?}/${tid:?}.branch"; echo "CLOSED $tid $lane $url";;
        CHANGES) printf '%s\n' "$r" | tail -n +2 > "$prd/$tid.changes"; echo "CHANGES $tid $lane $url";;
        *) echo "WAITING $tid $lane $url $s";;
      esac
    done < <(bash "$here/crew-tasks.sh" "$proj" with pr)
    for n in $(bash "$here/crew-tasks.sh" "$proj" issuedeps); do
      [ -f "$prd/issue-$n.closed" ] && continue
      case "$(issue_state "$n")" in
        CLOSED|MERGED) : > "$prd/issue-$n.closed"; : > "$prd/needs-ff"; echo "ISSUE-CLOSED $n";;
        *) echo "WAITING-ISSUE $n";;
      esac
    done
    # QA reads the main tree, so merged work has to arrive there: fast-forward only, never over the user's changes
    if per_task && [ -f "$prd/needs-ff" ]; then
      b=$(base_branch)
      if [ "$(git -C "$proj" symbolic-ref --short -q HEAD)" = "$b" ] && git -C "$proj" fetch -q origin "$b" 2>/dev/null && git -C "$proj" merge -q --ff-only "origin/$b" >/dev/null 2>&1; then rm -f "${prd:?}/needs-ff"
      else echo "SYNC-FAIL could not fast-forward $b in $proj (be on $b with no conflicting local changes, then rerun)"; fi
    fi ;;
  *) sed -n 2,15p "$0"; exit 2 ;;
esac
