#!/usr/bin/env bash
# Shared services the lanes depend on (a database container, an object store, a dev server). When one dies every lane fails at once
# for a reason no code change fixes. Optional .devin-crew/services.txt, one per line, tab separated, `#` comments:
#   <name><TAB><health command><TAB><restart command, optional>
#   bash crew-services.sh <project> check    run every health command: `OK   <name>` / `DOWN <name> | ...`; exit 1 if any is down. Changes nothing.
#   bash crew-services.sh <project> tick     the conductor's call: check, run the restart command of what is down (CREW_SERVICE_RESTARTS=3
#                                            times per outage), record what stays down in .devin-crew/env.down (lanes see it when they read
#                                            mail, the router holds wake-ups). Prints `RESTARTED <name>` / `DOWN <name>`; exit 1 while down.
#   bash crew-services.sh <project> reset    forget outage state and restart counts
# Commands run from the project root, unattended: only the user's approved plan puts them there.
# env: CREW_SERVICE_SECS=20 per health check | CREW_SERVICE_RESTART_SECS=120 per restart | CREW_SERVICE_BOOT=30 wait for health after it
set -u
proj=$(cd "$1" && pwd -P) || exit 2
cmd=${2:-check}; crew="$proj/.devin-crew"; list="$crew/services.txt"; state="$crew/services.state"
. "$(cd "$(dirname "$0")" && pwd)/crew-lib.sh"
if [ "$cmd" = reset ]; then rm -f "${crew:?}/env.down" "${state:?}"/*.tries 2>/dev/null; exit 0; fi
case "$cmd" in check|tick) ;; *) sed -n 2,13p "$0"; exit 2;; esac
[ -f "$list" ] || exit 0
[ "$cmd" = check ] || mkdir -p "$state"
out=$(mktemp) || exit 2; trap 'rm -f "${out:?}"' EXIT
healthy() { run_limited "${CREW_SERVICE_SECS:-20}" "$1" "$out" "$proj"; }
down=""
while IFS=$'\t' read -r -u 3 name health restart || [ -n "${name:-}" ]; do
  case "${name:-}" in ''|'#'*) name=""; continue;; esac
  if healthy "${health:-false}"; then
    [ "$cmd" = check ] && echo "OK   $name"
    [ "$cmd" = tick ] && rm -f "${state:?}/${name//[!A-Za-z0-9._-]/_}.tries"
  elif [ "$cmd" = check ]; then
    down="$down $name"; echo "DOWN $name | health: ${health:-none}${restart:+ | restart: $restart}"
  else
    date +%s > "$crew/env.last"   # a lane run that overlaps this does not pay for its failures
    tf="$state/${name//[!A-Za-z0-9._-]/_}.tries"; tries=$(cat "$tf" 2>/dev/null || echo 0); up=0
    if [ -n "${restart:-}" ] && [ "$tries" -lt "${CREW_SERVICE_RESTARTS:-3}" ]; then
      echo $((tries + 1)) > "$tf"
      run_limited "${CREW_SERVICE_RESTART_SECS:-120}" "$restart" "$out" "$proj"
      t0=$(date +%s)
      while :; do
        healthy "${health:-false}" && { up=1; break; }
        [ $(( $(date +%s) - t0 )) -ge "${CREW_SERVICE_BOOT:-30}" ] && break
        sleep 1
      done
    fi
    if [ "$up" = 1 ]; then echo "RESTARTED $name"; else down="$down $name"; echo "DOWN $name"; fi
  fi
  name=""
done 3< "$list"
if [ "$cmd" = tick ]; then
  if [ -n "$down" ]; then
    since=$(head -1 "$crew/env.down" 2>/dev/null); printf '%s\n%s\n' "${since:-$(date +%s)}" "${down# }" > "$crew/env.down"
  else rm -f "${crew:?}/env.down"; fi
fi
[ -z "$down" ]
