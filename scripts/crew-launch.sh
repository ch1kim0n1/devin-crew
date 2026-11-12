#!/usr/bin/env bash
# Start a lane (or the mail router) detached and return at once. For agents without a "run in background" tool
# (Codex, shells): pair with crew-wait.sh. Claude Code can keep using run_in_background directly.
#   bash crew-launch.sh <project> lane <lane> <model|-> <task_file|->      env (CREW_ROLE, CREW_GIT, ...) is passed through
#   bash crew-launch.sh <project> router [poll_secs]
# Output: lane/router pid and the log to read. The lane's own files (.devin-crew/lanes/<lane>.*) are written by devin-lane.sh.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
what=${2:-}; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"
mkdir -p "$crew/logs" "$crew/lanes"
case "$what" in
  lane)
    lane=${3:?lane}; model=${4:--}; task=${5:--}; out="$crew/logs/$lane-launch.out"
    # refuse early with the same message devin-lane.sh would give, so the caller sees why nothing started
    if [ -f "$crew/lanes/$lane.needs-user" ] && [ "${CREW_RETRY_OK:-0}" != 1 ]; then
      echo "lane $lane is waiting on the user after a Devin error ($(head -1 "$crew/lanes/$lane.needs-user")): tell them; relaunch only after they say retry (CREW_RETRY_OK=1)" >&2; exit 5; fi
    nohup bash "$here/devin-lane.sh" "$proj" "$lane" "$model" "$task" >"$out" 2>&1 </dev/null &
    lp=$!
    # return only once the lane has registered itself (pid file) or already exited, so an immediate crew-wait cannot miss it
    for _ in $(seq 1 50); do [ -f "$crew/lanes/$lane.pid" ] && break; kill -0 "$lp" 2>/dev/null || break; sleep 0.2; done
    echo "launched lane $lane pid $lp (output: $out)";;
  router)
    out="$crew/logs/router.out"; : > "$out"
    nohup bash "$here/crew-router.sh" "$proj" ${3:+"$3"} >"$out" 2>&1 </dev/null &
    echo $! > "$crew/router.pid"; echo "launched router pid $! (output: $out)";;
  *) echo "usage: crew-launch.sh <project> lane <lane> <model|-> <task_file|-> | router [poll]" >&2; exit 2;;
esac
