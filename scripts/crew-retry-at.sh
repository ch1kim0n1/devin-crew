#!/usr/bin/env bash
# Retry a lane that stopped on a Devin error, at a time the USER approved. Run me with Bash run_in_background=true,
# and only after the user said yes to "retry at <time>?". Sleeps, then relaunches the lane with CREW_RETRY_OK=1.
#   bash crew-retry-at.sh <project> <lane> <when> [task_file]
#   when: epoch seconds | +<seconds> | auto (parse the reset time from the lane's log, see `crew-observe.sh <p> <lane> --reset`)
# Without task_file the lane is resumed with "your last turn was cut off by <class>, continue your task".
# Refuses lanes that are not waiting on a Devin error, waits at most CREW_RETRY_MAX_WAIT (43200 s).
set -u
proj=$(cd "$1" && pwd -P) || exit 2
lane=${2:?lane}; when=${3:?when}; task=${4:-}
crew="$proj/.devin-crew"; here="$(cd "$(dirname "$0")" && pwd)"; nu="$crew/lanes/$lane.needs-user"
[ -f "$nu" ] || { echo "$lane is not waiting on a Devin error: nothing to retry" >&2; exit 2; }
now=$(date +%s)
case "$when" in
  auto) at=$(bash "$here/crew-observe.sh" "$proj" "$lane" --reset); [ -n "$at" ] || { echo "no reset time in the log: give an explicit time" >&2; exit 2; };;
  +*) at=$((now + ${when#+}));;
  *) at=$when;;
esac
case "$at" in ''|*[!0-9]*) echo "bad time '$when'" >&2; exit 2;; esac
[ "$at" -lt "$now" ] && at=$now
[ $((at - now)) -gt "${CREW_RETRY_MAX_WAIT:-43200}" ] && { echo "reset is more than $(( ${CREW_RETRY_MAX_WAIT:-43200} / 3600 ))h away: ask the user" >&2; exit 2; }
cls=$(head -1 "$nu")
if [ -z "$task" ]; then
  [ -f "$crew/lanes/$lane.sid" ] || { echo "$lane has no session to resume: pass the original task file as 4th argument" >&2; exit 2; }
  mkdir -p "$crew/prompts"; task="$crew/prompts/$lane-retry.md"
  printf 'Your previous turn was cut off by a Devin error (%s), not by anything you did. Do not start over: look at the files you already changed, finish the remaining work of your task, run your verification, check your mail, and post your DONE line (or BLOCKED with one question).\n' "$cls" > "$task"
fi
echo "$at" > "$crew/lanes/$lane.retry-at"
echo "$(date '+%F %T') $lane retry scheduled for $(date -r "$at" '+%F %T' 2>/dev/null || date -d "@$at" '+%F %T') (user approved, was $cls)" >> "$crew/events.log"
echo "retry of $lane scheduled in $((at - now))s"
while [ "$(date +%s)" -lt "$at" ]; do sleep 1; done
rm -f "$crew/lanes/$lane.retry-at"
CREW_RETRY_OK=1 exec bash "$here/devin-lane.sh" "$proj" "$lane" - "$task"
