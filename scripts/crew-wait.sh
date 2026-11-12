#!/usr/bin/env bash
# Block until something worth reacting to happens, then print it and exit. Replaces "wait for the background-exit
# notification" for agents that do not get one (Codex, plain shells). Bounded: never blocks past max_secs.
#   bash crew-wait.sh <project> [max_secs=300]
# Prints one or more of (each reported once):
#   LANE-EXIT <lane> <status>             a lane left running (done / failed(n) / failed(stalled...) ...)
#   NEEDS-USER <lane> <class>             that lane stopped on a Devin error: tell the user now
#   ROUTER <final line>                   QUIESCENT | ORCHESTRATOR-MAIL n | QUIESCENT-WITH-STUCK-MAIL ... | ROUTER-TIMEOUT
#   NOTHING-RUNNING                       no lane running, router not running, nothing new
#   WAIT-TIMEOUT after <n>s; running: ... nothing new yet; call again (do not poll faster than every few minutes)
# Exit: 0 something reported, 3 timeout, 4 nothing running.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
max=${2:-300}; crew="$proj/.devin-crew"; t0=$(date +%s)
if stat -c %Y / >/dev/null 2>&1; then mt() { stat -c %Y "$1" 2>/dev/null; }; else mt() { stat -f %m "$1" 2>/dev/null; }; fi
scan() {
  local f lane st sig rep=0 running=""
  for f in "$crew"/lanes/*.status; do
    [ -e "$f" ] || continue
    lane=$(basename "$f" .status); st=$(cat "$f")
    case "$st" in
      running|waking) running="$running $lane"; continue;;
    esac
    sig="$st $(mt "$f")"
    if [ "$(cat "$crew/lanes/$lane.reported" 2>/dev/null)" != "$sig" ]; then
      echo "$sig" > "$crew/lanes/$lane.reported"; echo "LANE-EXIT $lane $st"; rep=1
      [ -f "$crew/lanes/$lane.needs-user" ] && echo "NEEDS-USER $lane $(head -1 "$crew/lanes/$lane.needs-user")"
    fi
  done
  if [ -s "$crew/logs/router.out" ]; then
    last=$(grep -E '^(QUIESCENT|ORCHESTRATOR-MAIL|ROUTER-TIMEOUT)' "$crew/logs/router.out" | tail -1)
    if [ -n "$last" ]; then echo "ROUTER $last"; mv "$crew/logs/router.out" "$crew/logs/router.last"; rm -f "$crew/router.pid"; rep=1; fi
  fi
  RUNNING=$running; return $((1 - rep))
}
router_alive() { local p; p=$(cat "$crew/router.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
while :; do
  if scan; then exit 0; fi
  if [ -z "$RUNNING" ] && ! router_alive; then echo "NOTHING-RUNNING"; exit 4; fi
  [ $(( $(date +%s) - t0 )) -ge "$max" ] && { echo "WAIT-TIMEOUT after ${max}s; running:${RUNNING:- none (router only)}"; exit 3; }
  sleep 3
done
