#!/usr/bin/env bash
# Lane-minutes budget: total wall-clock minutes all lanes have run (parallel lanes add up), a cost and time proxy.
#   bash crew-budget.sh <project> set <minutes>   write .devin-crew/BUDGET ("none" removes it)
#   bash crew-budget.sh <project> check           one line; exit 0 ok or no budget, 1 at 80% or more, 2 exceeded
# devin-lane.sh and crew-router.sh refuse to start lanes once exceeded (override: CREW_BUDGET_OVERRIDE=1, only after the user said so).
set -u
proj=$(cd "$1" && pwd -P) || exit 2
cmd=${2:-check}; crew="$proj/.devin-crew"; f="$crew/BUDGET"
case "$cmd" in
  set)
    case "${3:-}" in
      none) rm -f "$f"; echo "budget: none";;
      ''|*[!0-9]*) echo "usage: set <minutes>|none" >&2; exit 2;;
      *) mkdir -p "$crew"; echo "$3" > "$f"; echo "budget: $3 lane-minutes";;
    esac;;
  check)
    [ -s "$f" ] || { echo "budget: none set"; exit 0; }
    cap=$(cat "$f"); now=$(date +%s); secs=0
    if [ -s "$crew/events.log" ]; then
      secs=$(awk '$4=="exit" { if (match($0,/elapsed=[0-9]+/)) s+=substr($0,RSTART+8,RLENGTH-8) } END{print s+0}' "$crew/events.log")
    fi
    for s in "$crew"/lanes/*.status; do   # lanes running right now have no exit event yet
      [ -e "$s" ] || continue
      lane=$(basename "$s" .status)
      if [ "$(cat "$s")" = running ] && [ -s "$crew/lanes/$lane.started" ]; then secs=$((secs + now - $(cat "$crew/lanes/$lane.started"))); fi
    done
    used=$((secs / 60)); pct=$((used * 100 / cap))
    echo "budget: $used of $cap lane-minutes used (${pct}%)"
    [ "$used" -ge "$cap" ] && { echo "BUDGET EXCEEDED: stop launching and ask the user whether to raise it"; exit 2; }
    [ "$pct" -ge 80 ] && { echo "budget: over 80%, tell the user before the next wave"; exit 1; }
    exit 0;;
  *) echo "usage: crew-budget.sh <project> set|check" >&2; exit 2;;
esac
