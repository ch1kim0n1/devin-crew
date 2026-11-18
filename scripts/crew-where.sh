#!/usr/bin/env bash
# Where is this project in the crew's life? One call that tells the conductor what `/devin-crew` (with or without text) should do now.
#   bash crew-where.sh [project]
# Prints at most 5 lines: `STATE <name>`, `GOAL: ...` (when known), `SETUP: ...` (only when Devin itself is not ready), `NEXT: ...` (what to do, plainly).
# States: NO-CREW | DRAFTING | DRAFT-FAILED | DRAFT-READY | RUNNING | ATTENTION | DONE | STOPPED | NEEDS-USER | MANUAL-RUNNING
# Changes nothing, runs no Devin.
set -u
proj=$(cd "${1:-.}" && pwd -P) || { echo "STATE NO-CREW"; echo "NEXT: the folder does not exist"; exit 0; }
crew="$proj/.devin-crew"; ap="$crew/autopilot"
st() { cat "$crew/lanes/$1.status" 2>/dev/null; }
goal=$(grep -iE '^#* *(objective|goal):' "$crew/PLAN.md" 2>/dev/null | head -1 | sed -E 's/^#* *[A-Za-z]+: *//' | cut -c1-120)
[ -n "$goal" ] || goal=$(grep -iE '^#* *(objective|goal):' "$crew/draft/PLAN.md" 2>/dev/null | head -1 | sed -E 's/^#* *[A-Za-z]+: *//' | cut -c1-120)
pid=$(cat "$ap/pid" 2>/dev/null); alive=0; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
state=NO-CREW; next="ask the user for the goal in one line, then draft a plan"
nu=""; for f in "$crew"/lanes/*.needs-user; do [ -e "$f" ] && { nu=$(basename "$f" .needs-user); break; }; done
if [ -f "$ap/DONE" ]; then state=DONE; next="tell the user it is finished: the report and the pull request link (.devin-crew/autopilot/DONE, REPORT.md, PR_URL); offer a next goal"
elif [ -f "$ap/ATTENTION" ]; then state=ATTENTION; next="read .devin-crew/autopilot/ATTENTION; a Devin error goes to the user now, anything else is your decision; then restart the autopilot"
elif [ -n "$nu" ]; then state=NEEDS-USER; next="lane $nu stopped on a Devin error (.devin-crew/lanes/$nu.needs-user): tell the user the cause and their fix; retry only on their word"
elif [ "$alive" = 1 ]; then state=RUNNING; next="tell the user in two lines how far it is (autopilot --status) and that you will report when it ends; keep a background autopilot --wait going"
elif [ -f "$crew/PLAN.md" ] && grep -q '^approved:' "$crew/PLAN.md" 2>/dev/null; then
  running=0; for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; case "$(cat "$f")" in running|waking) running=$((running + 1));; esac; done
  if [ "$running" -gt 0 ]; then state=MANUAL-RUNNING; next="lanes are running without the autopilot: crew-resume.sh, then follow its NEXT list"
  else state=STOPPED; next="an approved plan exists and nothing is running: confirm with the user, then continue it (crew-autopilot.sh --detach, background --wait)"; fi
elif [ -s "$crew/draft/PLAN.md" ] && [ "$(st plan)" = "done" ]; then state=DRAFT-READY; next="crew-plan.sh check, ask the architect's questions in one message, show the one-page plan and ask go / go with a pull request / change"
elif [ "$(st plan)" = running ] || [ "$(st plan)" = waking ]; then state=DRAFTING; next="the architect is still drafting: wait for it (crew-wait.sh), do not start another"
else case "$(st plan)" in failed*) state=DRAFT-FAILED; next="the architect lane failed: crew-observe.sh <project> plan, tell the user the cause (a Devin error goes to them), then draft again";; esac
fi
echo "STATE $state"
[ -n "$goal" ] && echo "GOAL: $goal"
if [ "$state" = NO-CREW ] || [ "$state" = DRAFT-FAILED ]; then
  if ! command -v devin >/dev/null 2>&1; then echo "SETUP: the Devin CLI is not installed: tell the user to install it and run 'devin auth login'"
  elif ! devin auth status >/dev/null 2>&1; then echo "SETUP: Devin is not logged in: tell the user to run 'devin auth login'"; fi
fi
echo "NEXT: $next"
exit 0
