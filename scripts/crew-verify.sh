#!/usr/bin/env bash
# Mechanical checks on finished lanes. Changes nothing but .devin-crew/verify.log.
#   bash crew-verify.sh <project> [lane]
# 1. Runs each TASKS.md row's acceptance command (column 5) for every lane that is not running.
#    Row format: | id | lane | scope | depends | acceptance | status |   (acceptance must not contain '|')
# 2. Contract freshness: a lane's last DONE line must say `contracts: v<N>` with N = current CONTRACTS.md version.
# Exit 1 if any acceptance fails/times out or any lane built against a stale contract.
# env: CREW_VERIFY_SECS=300 per-command timeout
set -u
proj=$(cd "$1" && pwd) || exit 2
only=${2:-}
crew="$proj/.devin-crew"; secs=${CREW_VERIFY_SECS:-300}
[ -d "$crew" ] || { echo "no crew in $proj"; exit 0; }
log="$crew/verify.log"; : > "$log"
bad=0
say() { echo "$*" | tee -a "$log"; }
trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }

# ponytail: no coreutils `timeout` on macOS, so a background sleeper does the killing
run_limited() { # secs cmd outfile -> exit code (124 = timed out)
  local p w rc
  rm -f "$3.to"
  (cd "$proj" && exec bash -c "$2") >"$3" 2>&1 & p=$!
  ( sleep "$1"; kill -0 "$p" 2>/dev/null || exit 0; : > "$3.to"; kill -TERM "$p" 2>/dev/null; sleep 2; kill -KILL "$p" 2>/dev/null ) 2>/dev/null & w=$!
  disown "$w" 2>/dev/null
  wait "$p"; rc=$?
  pkill -P "$w" 2>/dev/null; kill "$w" 2>/dev/null
  if [ -e "$3.to" ]; then rc=124; rm -f "$3.to"; fi
  return "$rc"
}

lane_running() { [ "$(cat "$crew/lanes/$1.status" 2>/dev/null)" = running ]; }

if [ -f "$crew/TASKS.md" ]; then
  out=$(mktemp)
  while IFS='|' read -r _ id lane _ _ acc _; do
    id=$(trim "$id"); lane=$(trim "$lane"); acc=$(trim "$acc")
    case "$id" in ''|id|-*|:*) continue;; esac
    [ -n "$only" ] && [ "$lane" != "$only" ] && continue
    case "$acc" in ''|-|n/a|N/A) say "SKIP $id $lane: no acceptance command"; continue;; esac
    [ -f "$crew/lanes/$lane.status" ] || { say "SKIP $id $lane: lane not started"; continue; }
    if lane_running "$lane"; then say "SKIP $id $lane: lane still running"; continue; fi
    run_limited "$secs" "$acc" "$out"; rc=$?
    tasks="$(cd "$(dirname "$0")" && pwd)/crew-tasks.sh"
    if [ "$rc" -eq 0 ]; then bash "$tasks" "$proj" set "$id" "done"; say "PASS $id $lane: $acc"
    elif [ "$rc" -eq 124 ]; then bad=1; bash "$tasks" "$proj" set "$id" failed; say "TIMEOUT $id $lane (>${secs}s): $acc"; tail -n 5 "$out" | sed 's/^/    /' | tee -a "$log"
    else bad=1; bash "$tasks" "$proj" set "$id" failed; say "FAIL $id $lane (exit $rc): $acc"; tail -n 5 "$out" | sed 's/^/    /' | tee -a "$log"; fi
  done < "$crew/TASKS.md"
  rm -f "$out"
else say "no TASKS.md: acceptance checks skipped"; fi

if [ -f "$crew/CONTRACTS.md" ]; then
  cur=$(head -1 "$crew/CONTRACTS.md" | sed 's/[^0-9]//g')
  for f in "$crew"/lanes/*.status; do
    [ -e "$f" ] || continue
    lane=$(basename "$f" .status)
    [ -n "$only" ] && [ "$lane" != "$only" ] && continue
    d=$(grep -E "DONE $lane:" "$crew/BOARD.md" 2>/dev/null | tail -1)
    [ -z "$d" ] && continue
    seen=$(printf '%s' "$d" | sed -n 's/.*contracts: v\([0-9][0-9]*\).*/\1/p')
    if [ -z "$seen" ]; then say "NO-CONTRACT-VERSION $lane: DONE line has no 'contracts: vN' (current v$cur)"
    elif [ "$seen" != "$cur" ]; then bad=1; say "STALE-CONTRACT $lane: built against v$seen, CONTRACTS.md is v$cur"
    else say "CONTRACT-OK $lane: v$seen"; fi
  done
fi
say "verify: $([ "$bad" -eq 0 ] && echo clean || echo PROBLEMS)"
exit "$bad"
