#!/usr/bin/env bash
# Mail router as a process: wakes idle lanes that have unread mail, and exits when the crew is quiet.
# Run me with Bash run_in_background=true: my exit is the one notification you need before QA.
#   bash crew-router.sh <project> [poll_secs=15]
# Prints one final line and exits:
#   QUIESCENT                          no lane running, no mail left to deliver
#   ORCHESTRATOR-MAIL <n>              mail for you; read it, then start me again
#   QUIESCENT-WITH-STUCK-MAIL ...      lanes that cannot be auto-woken (stalled/timeout/never started) have unread mail
#   ROUTER-TIMEOUT                     CREW_ROUTER_MAX_SECS (7200) passed
# Only lanes with status `done` or `failed(<number>)` are woken; stalled/timeout lanes need your judgment first.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
poll=${2:-15}; max=${CREW_ROUTER_MAX_SECS:-7200}
here="$(cd "$(dirname "$0")" && pwd)"
crew="$proj/.devin-crew"; mkdir -p "$crew/lanes" "$crew/logs"
ev() { echo "$(date '+%F %T') router $*" >> "$crew/events.log"; }
t0=$(date +%s); idle=0
ev "router start"
while :; do
  [ $(( $(date +%s) - t0 )) -ge "$max" ] && { ev "router timeout"; echo "ROUTER-TIMEOUT"; exit 3; }
  running=0; woke=0; stuck=""; orch=0
  for f in "$crew"/lanes/*.status; do
    [ -e "$f" ] || continue
    case "$(cat "$f")" in running|waking) running=$((running + 1));; esac
  done
  while read -r lane st n; do
    [ -z "$lane" ] && continue
    if [ "$lane" = orchestrator ]; then orch=$n; continue; fi
    case "$st" in
      done|failed\([0-9]*\))
        echo waking > "$crew/lanes/$lane.status"; ev "wake $lane ($n unread, was $st)"
        nohup bash "$here/devin-lane.sh" "$proj" "$lane" - - >> "$crew/logs/router.log" 2>&1 &
        woke=$((woke + 1)); running=$((running + 1));;
      running|waking) ;;
      *) stuck="$stuck $lane($st,$n)";;
    esac
  done < <(bash "$here/lane-msg.sh" "$proj" pending)
  if [ "$orch" -gt 0 ]; then ev "orchestrator mail $orch"; echo "ORCHESTRATOR-MAIL $orch"; exit 0; fi
  if [ "$running" -eq 0 ] && [ "$woke" -eq 0 ]; then idle=$((idle + 1)); else idle=0; fi
  if [ "$idle" -ge 2 ]; then
    ev "quiescent${stuck:+ stuck:$stuck}"
    if [ -n "$stuck" ]; then echo "QUIESCENT-WITH-STUCK-MAIL$stuck"; else echo "QUIESCENT"; fi
    exit 0
  fi
  sleep "$poll"
done
