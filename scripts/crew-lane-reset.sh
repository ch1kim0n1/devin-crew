#!/usr/bin/env bash
# Recover a failed or stuck lane in one step, so the conductor can relaunch it cleanly.
#   bash crew-lane-reset.sh <project> <lane>... [--keep-session]
# Does, per lane: reopens its failed/running tasks (review and done stay), sets the conductor state to idle, clears the
# NEEDS-USER flag and any BRAIN note, clears the lane's stored model (so the MODEL file or CREW_MODEL applies on relaunch),
# and moves the Devin session aside (lanes/<lane>.sid.<time>; kept, not deleted) so the relaunch starts a fresh session.
# --keep-session leaves the session in place (resume it). It never launches anything and never approves a retry: after a
# Devin error the user's word is still needed (CREW_RETRY_OK=1 on the next launch).
set -u
proj=$(cd "$1" && pwd -P) || exit 2; shift
keep=0; lanes=()
for a in "$@"; do case "$a" in --keep-session) keep=1;; *) lanes+=("$a");; esac; done
[ ${#lanes[@]} -gt 0 ] || { echo "usage: crew-lane-reset.sh <project> <lane>... [--keep-session]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; cd_dir="$crew/conduct"; mkdir -p "$cd_dir"
for l in "${lanes[@]}"; do
  case "$l" in *[!A-Za-z0-9._-]*|"") echo "bad lane name: $l" >&2; continue;; esac
  if [ -f "$crew/lanes/$l.pid" ] && kill -0 "$(cat "$crew/lanes/$l.pid" 2>/dev/null)" 2>/dev/null; then
    echo "$l: still running, not touched (stop it first)"; continue; fi
  bash "$here/crew-tasks.sh" "$proj" lane "$l" "failed|running" open
  echo idle > "$cd_dir/$l.state"; rm -f "$cd_dir/$l.brain" "$cd_dir/$l.reported" "$crew/lanes/$l.needs-user" "$crew/lanes/$l.model"
  echo 0 > "$cd_dir/$l.launched"; echo 0 > "$cd_dir/$l.fix"
  if [ "$keep" = 0 ] && [ -f "$crew/lanes/$l.sid" ]; then mv "$crew/lanes/$l.sid" "$crew/lanes/$l.sid.$(date +%H%M%S)"; fi
  echo "$(date '+%F %T') $l lane reset (tasks reopened, model and ${keep:+session }flags cleared)" >> "$crew/events.log"
  echo "$l: reset. Next: relaunch via the conductor (crew-autopilot.sh --detach); after a Devin error add CREW_RETRY_OK=1 only with the user's word."
done
