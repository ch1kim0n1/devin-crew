#!/usr/bin/env bash
# Run (or resume) one Devin "lane" headless. Run me with Bash run_in_background=true.
# usage: bash devin-lane.sh <project_dir> <lane> <model|-> <task_file|-> [permission_mode=dangerous]
#   model "-"      reuse the model this lane was first launched with (always swe-2-flash-high)
#   task_file "-"  wake-up: the lane only gets "you have new mail"
# env: CREW_ROLE=<name>        first launch only: append templates/roles/<name>.md to the preamble
#      CREW_MAX_SECS=2700      wall-clock cap per turn, nudges included (status failed(timeout))
#      CREW_STALL_RETRIES=2    automatic kill+nudge attempts when the lane stalls (see crew-observe.sh)
# First call for a lane starts a new Devin session; later calls resume it, unread mail prepended.
# A lane with .devin-crew/lanes/<lane>.workdir (see crew-worktree.sh) runs inside that git worktree.
# dangerous = Devin's bypass mode (auto-approves all tools), the user's chosen default for every lane.
set -u
proj=$(cd "$1" && pwd) || exit 2
lane=$2; model=$3; task=$4; perm=${5:-dangerous}
crew="$proj/.devin-crew"
mkdir -p "$crew/lanes" "$crew/logs"
sid_file="$crew/lanes/$lane.sid"; model_file="$crew/lanes/$lane.model"
skill_dir=$(cd "$(dirname "$0")/.." && pwd)
msg="$skill_dir/scripts/lane-msg.sh"; obs="$skill_dir/scripts/crew-observe.sh"
workdir="$proj"; [ -f "$crew/lanes/$lane.workdir" ] && workdir=$(cat "$crew/lanes/$lane.workdir")
ev() { echo "$(date '+%F %T') $lane $*" >> "$crew/events.log"; }

if [ "$model" = "-" ]; then model=$(cat "$model_file" 2>/dev/null) || model=swe-2-flash-high; fi
# User's standing rule (2026-11-09): lanes ALWAYS run swe-2-flash-high. Anything else is coerced.
if [ "$model" != "swe-2-flash-high" ]; then
  echo "model '$model' not allowed, using swe-2-flash-high" >&2; model=swe-2-flash-high
fi
echo "$model" > "$model_file"

n=0; for f in "$crew/logs/$lane".[0-9]*.log; do [ -e "$f" ] && n=$((n + 1)); done
log="$crew/logs/$lane.$((n + 1)).log"

body=""; [ "$task" != "-" ] && body=$(cat "$task")
if [ -f "$sid_file" ]; then
  resume=(-r "$(cat "$sid_file")")
  mail=$(bash "$msg" "$proj" read "$lane")
  [ "$task" = "-" ] && body="You were woken because you have new mail. Handle every message, finish any work it implies, then append an updated DONE line to $crew/BOARD.md and reply with the same summary."
  prompt=$(printf 'NEW MAIL (from other lanes):\n%s\n\n%s' "$mail" "$body")
  ev "resume session $(cat "$sid_file")"
else
  resume=()
  [ "$task" = "-" ] && { echo "first launch needs a task file" >&2; exit 2; }
  t=$(cat "$skill_dir/templates/preamble.md")
  t=${t//\{\{LANE\}\}/$lane}; t=${t//\{\{PROJECT\}\}/$proj}; t=${t//\{\{WORKDIR\}\}/$workdir}
  t=${t//\{\{CREW\}\}/$crew}; t=${t//\{\{SKILLDIR\}\}/$skill_dir}
  role=""; [ -n "${CREW_ROLE:-}" ] && [ -f "$skill_dir/templates/roles/$CREW_ROLE.md" ] && role=$(cat "$skill_dir/templates/roles/$CREW_ROLE.md")
  prompt=$(printf '%s\n\n%s\n\n%s' "$t" "$role" "$body")
  ev "launch ${CREW_ROLE:-no-role} in $workdir"
fi

echo $$ > "$crew/lanes/$lane.pid"; date +%s > "$crew/lanes/$lane.started"
echo running > "$crew/lanes/$lane.status"
cd "$workdir" || exit 2
max=${CREW_MAX_SECS:-2700}; retries=${CREW_STALL_RETRIES:-2}; t0=$(date +%s); start=$t0
: > "$log"

# run_turn <prompt> [devin args...]: one devin -p turn with a watchdog.
# Sets: code, timedout (0/1), stall_reason ("" or "<STATE>: why"). Returns when devin exits or is killed.
run_turn() {
  local p=$1; shift
  stall_reason=""; timedout=0; start=$(date +%s)   # the wall-clock cap is per turn, so a nudge gets a fresh budget
  devin -p "$p" --model "$model" --permission-mode "$perm" --export "$crew/lanes/$lane.export.json" "$@" >>"$log" 2>&1 &
  local dpid=$!; echo "$dpid" > "$crew/lanes/$lane.devinpid"
  local next_check=$(( $(date +%s) + 90 )) now r rc tool_kills=0
  while kill -0 "$dpid" 2>/dev/null; do
    sleep 2; now=$(date +%s)
    if [ $((now - start)) -ge "$max" ]; then
      timedout=1; ev "TIMEOUT after ${max}s, killing"
      pkill -TERM -P "$dpid" 2>/dev/null; kill -TERM "$dpid" 2>/dev/null; sleep 3
      pkill -KILL -P "$dpid" 2>/dev/null; kill -KILL "$dpid" 2>/dev/null; break
    fi
    if [ "$now" -ge "$next_check" ]; then
      next_check=$((now + 30))
      r=$(bash "$obs" "$proj" "$lane" --stall); rc=$?
      if [ "$rc" -eq 4 ] && [ "$tool_kills" -lt 3 ]; then
        # a command Devin started is hung: kill that command only; Devin sees a failed tool call and carries on
        tool_kills=$((tool_kills + 1)); ev "HUNG-TOOL ($r): killing its commands (#$tool_kills)"
        for c in $(pgrep -P "$dpid" 2>/dev/null); do pkill -TERM -P "$c" 2>/dev/null; done
        next_check=$((now + 120))
      elif [ "$rc" -ne 0 ]; then
        stall_reason=$r; ev "STALL detected ($r): killing devin"
        pkill -TERM -P "$dpid" 2>/dev/null; kill -TERM "$dpid" 2>/dev/null; sleep 3
        pkill -KILL -P "$dpid" 2>/dev/null; kill -KILL "$dpid" 2>/dev/null; break
      fi
    fi
  done
  wait "$dpid" 2>/dev/null; code=$?
  rm -f "$crew/lanes/$lane.devinpid"
}

run_turn "$prompt" ${resume[@]+"${resume[@]}"}
attempt=0
while [ -n "$stall_reason" ] && [ "$timedout" -eq 0 ] && [ "$attempt" -lt "$retries" ]; do
  attempt=$((attempt + 1))
  sid=$(bash "$obs" "$proj" "$lane" --sid); [ -z "$sid" ] && break
  echo "$sid" > "$sid_file"
  ev "NUDGE $attempt/$retries on session $sid after: $stall_reason"
  echo "--- crew watchdog: stalled ($stall_reason); nudge $attempt/$retries ---" >> "$log"
  nudge="Your previous turn stopped producing output (diagnosis: $stall_reason). Do not start over. Look at the files you already changed, finish the remaining work of your task, run your verification, check your mail, and post your DONE line (or BLOCKED with one question). If a command hangs, run it with a timeout."
  run_turn "$nudge" -r "$sid"
done

# ponytail: session id comes from the export file, falling back to Devin's own session store
sid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_id"])' "$crew/lanes/$lane.export.json" 2>/dev/null)
[ -z "$sid" ] && sid=$(bash "$obs" "$proj" "$lane" --sid)
[ -n "$sid" ] && echo "$sid" > "$sid_file"
if [ "$timedout" -eq 1 ]; then st="failed(timeout)"
elif [ -n "$stall_reason" ]; then st="failed(stalled: ${stall_reason%%:*})"
elif [ "$code" -eq 0 ]; then st="done"
else st="failed($code)"; fi
echo "$st" > "$crew/lanes/$lane.status"
rm -f "$crew/lanes/$lane.pid"
ev "exit status=$st session=${sid:-unknown} elapsed=$(( $(date +%s) - t0 )) nudges=$attempt"
echo "lane=$lane status=$st session=${sid:-unknown} log=$log"
[ "$st" = "done" ] || echo "diagnose: bash $skill_dir/scripts/crew-observe.sh $proj $lane"
if [ "$st" = "done" ]; then exit 0; fi
exit "${code:-1}"
