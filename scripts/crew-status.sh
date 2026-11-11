#!/usr/bin/env bash
# One-screen view of a crew run: tasks, lanes, mail, lock. Safe to run any time, changes nothing.
#   bash crew-status.sh <project>
# TASKS.md rows end in a status cell: open | running | review | done | failed.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
crew="$proj/.devin-crew"
[ -d "$crew" ] || { echo "no crew in $proj"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"

count() { grep -ciE "\|[[:space:]]*$1[[:space:]]*\|?[[:space:]]*$" "$crew/TASKS.md" 2>/dev/null || true; }
if [ -f "$crew/TASKS.md" ]; then
  echo "tasks: open=$(count open) running=$(count running) review=$(count review) done=$(count "done") failed=$(count failed)"
else echo "tasks: no TASKS.md"; fi
[ -f "$crew/LOCK" ] && echo "lock: held $(( $(date +%s) - $(head -1 "$crew/LOCK") ))s ago"
[ -f "$crew/baseline.cmd" ] && echo "baseline: exit $(cat "$crew/baseline.exit") for: $(cat "$crew/baseline.cmd")"

bash "$here/crew-budget.sh" "$proj" check | head -1
pending=$(bash "$here/lane-msg.sh" "$proj" pending)
for f in "$crew"/lanes/*.status; do
  [ -e "$f" ] || { echo "lanes: none"; break; }
  lane=$(basename "$f" .status); st=$(cat "$f")
  if [ "$st" = running ]; then
    pid=$(cat "$crew/lanes/$lane.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      v=$(bash "$here/crew-observe.sh" "$proj" "$lane" --stall)
      st="running $(( $(date +%s) - $(cat "$crew/lanes/$lane.started") ))s ${v%%:*}"
    else st="running-but-NO-PROCESS (crashed; treat as failed)"; fi
  fi
  mail=$(echo "$pending" | awk -v l="$lane" '$1==l{print $3}'); mail=${mail:-0}
  wt=""; [ -f "$crew/lanes/$lane.workdir" ] && wt=" worktree"
  [ -f "$crew/lanes/$lane.needs-user" ] && wt="$wt NEEDS-USER($(head -1 "$crew/lanes/$lane.needs-user"))"
  last=$(ls -t "$crew"/logs/"$lane".*.log 2>/dev/null | head -1)
  tail1=""; [ -n "$last" ] && tail1=$(grep -v '^[[:space:]]*$' "$last" | tail -1 | cut -c1-90)
  printf '%-10s %-44s unread=%s%s | %s\n' "$lane" "$st" "$mail" "$wt" "$tail1"
done
[ -f "$crew/events.log" ] && { echo "recent events:"; tail -4 "$crew/events.log" | sed 's/^/    /'; }
o=$(echo "$pending" | awk '$1=="orchestrator"{print $3}'); [ -n "$o" ] && echo "MAIL FOR ORCHESTRATOR: $o unread"
true
