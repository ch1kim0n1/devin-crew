#!/usr/bin/env bash
# Rebuild the picture of a crew run from files alone (after a context reset, a crash, or reopening the project),
# and say what to do next. Changes nothing.
#   bash crew-resume.sh <project>
set -u
proj=$(cd "$1" && pwd -P) || exit 2
crew="$proj/.devin-crew"
here="$(cd "$(dirname "$0")" && pwd)"
[ -d "$crew" ] || { echo "no crew in $proj: nothing to resume. Start with /devin-crew <goal>."; exit 0; }

echo "=== PLAN (what the user approved) ==="
if [ -f "$crew/PLAN.md" ]; then cat "$crew/PLAN.md"; else echo "NO PLAN.md: the approved plan is lost. Re-confirm goal, milestones, lanes and git rights with the user before launching anything."; fi
echo
echo "=== STATE ==="
bash "$here/crew-status.sh" "$proj"
[ -f "$crew/QA.md" ] && { echo "last QA verdicts:"; grep -E '^(##|VERDICT|Verdict)' "$crew/QA.md" | tail -6 | sed 's/^/    /'; }
echo
echo "=== NEXT ==="
n=0; say() { n=$((n + 1)); echo "$n. $*"; }

pending=$(bash "$here/lane-msg.sh" "$proj" pending)
echo "$pending" | awk '$1=="orchestrator"{f=1} END{exit !f}' && say "Mail for you: bash $here/lane-msg.sh $proj read orchestrator (answer from CONTRACTS.md, bump version if a contract changes)"

running=0
for f in "$crew"/lanes/*.status; do
  [ -e "$f" ] || continue
  lane=$(basename "$f" .status); st=$(cat "$f")
  case "$st" in
    running)
      pid=$(cat "$crew/lanes/$lane.pid" 2>/dev/null)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then running=$((running + 1)); say "Lane $lane is still running: leave it, wait for its exit."
      else say "Lane $lane says running but its process is gone (crashed or the machine restarted): bash $here/crew-observe.sh $proj $lane, then resume it with a narrower task (devin-lane.sh $proj $lane - <task_file>)."; fi;;
    waking) say "Lane $lane is stuck in 'waking' (the router died before it started): treat as idle, rerun crew-router.sh.";;
    failed*) say "Lane $lane is $st: bash $here/crew-observe.sh $proj $lane before deciding.";;
  esac
done
echo "$pending" | awk '$1!="orchestrator" && ($2=="done" || $2 ~ /^failed\([0-9]+\)$/){f=1} END{exit !f}' && say "Idle lanes have unread mail: start bash $here/crew-router.sh $proj in the background (it wakes them)."

if [ -f "$crew/TASKS.md" ]; then
  cnt() { grep -ciE "\|[[:space:]]*$1[[:space:]]*\|?[[:space:]]*$" "$crew/TASKS.md" 2>/dev/null || true; }
  rv=$(cnt review); fl=$(cnt failed); op=$(cnt open); rn=$(cnt running); dn=$(cnt "done")
  [ "${rv:-0}" -gt 0 ] && say "$rv task(s) in review: bash $here/crew-verify.sh $proj (runs acceptance, checks contract versions, marks done/failed)."
  [ "${fl:-0}" -gt 0 ] && say "$fl failed task(s): diagnose, then send the lane a correction (resume it) or reassign. Three failures of one task means ask the user."
  nx=$(bash "$here/crew-tasks.sh" "$proj" next)
  [ -n "$nx" ] && say "Launchable now (deps done, lane idle):$(echo "$nx" | awk '{printf " %s(%s)", $1, $2}'). Brief them per SKILL.md phase 4 (respect the plan's git rights and budget)."
  if [ "${op:-0}" -eq 0 ] && [ "${rn:-0}" -eq 0 ] && [ "${rv:-0}" -eq 0 ] && [ "${fl:-0}" -eq 0 ] && [ "${dn:-0}" -gt 0 ] && [ "$running" -eq 0 ]; then
    say "All tasks done: run milestone QA (crew-qa.sh, crew-verify.sh, reference/qa-checklist.md), write the verdict in QA.md; on PASS for every milestone, finish and report once."
  fi
else say "No TASKS.md: the run stopped before decomposition. Rebuild tasks from PLAN.md with the user's OK."; fi

[ -f "$crew/LOCK" ] && [ "$running" -eq 0 ] && say "Crew lock is held with no lane running: if no other session is working here, bash $here/crew-guard.sh $proj unlock."
[ "$n" -eq 0 ] && echo "(nothing pending: crew is idle and clean)"
true
