#!/usr/bin/env bash
# Conductor: runs the crew's routine loop WITHOUT the brain, so the brain wakes once per decision instead of once per step.
# Run me with Bash run_in_background=true. I launch every ready task in parallel (up to CREW_CONDUCT_MAX_LANES), and when a lane exits I
# collect it (acceptance, scope, contract), resume it with the printed failures if it can fix them, launch a read-only reviewer Devin,
# resume the lane with the review findings, and merge it when clean. I exit with ONE digest only when the brain is needed.
#   bash crew-conduct.sh <project>                 run until a reason below
#   bash crew-conduct.sh <project> --status        lane states, no side effects
#   bash crew-conduct.sh <project> --reset <lane> [state]   clear a lane's BRAIN state after you handled it (default state: launched = re-collect)
# Needs per task: .devin-crew/prompts/<task-id>.md (the brief); optional <task-id>.role (one word: implementer|tests|docs|refactor), default implementer.
# Final line (exit 0), one of:
#   CONDUCT MILESTONE-READY            every task done, every lane merged: run the milestone QA
#   CONDUCT BRAIN <lane>: <why>        needs judgment (scope breach, merge conflict, fixes exhausted, lane failed, launch refused)
#   CONDUCT NEEDS-USER <lane> <class>  Devin error: tell the user, retry only on their word (CREW_RETRY_OK=1)
#   CONDUCT ORCHESTRATOR-MAIL <n>      a lane mailed you
#   CONDUCT BUDGET                     lane-minute budget exceeded
#   CONDUCT STUCK <ids>                open tasks cannot launch (no brief, or dependencies not done)
#   CONDUCT TIMEOUT
# env: CREW_AUTOFIX=2 fix rounds per lane | CREW_AUTOREVIEW=1 (0 off) | CREW_REVIEW_PASSES=2 | CREW_MERGE=1 (worktree lanes) |
#      CREW_CONDUCT_MAX_LANES=5 | CREW_CONDUCT_POLL=10 | CREW_CONDUCT_MAX_SECS=7200
set -u
proj=$(cd "$1" && pwd -P) || exit 2
shift; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; cd_dir="$crew/conduct"; mkdir -p "$cd_dir" "$crew/prompts" "$crew/lanes" "$crew/logs"
autofix=${CREW_AUTOFIX:-2}; autorev=${CREW_AUTOREVIEW:-1}; passes=${CREW_REVIEW_PASSES:-2}; domerge=${CREW_MERGE:-1}
maxlanes=${CREW_CONDUCT_MAX_LANES:-5}; poll=${CREW_CONDUCT_POLL:-10}; maxsecs=${CREW_CONDUCT_MAX_SECS:-7200}
ev() { echo "$(date '+%F %T') conductor $*" >> "$crew/events.log"; }
st_of() { cat "$cd_dir/$1.state" 2>/dev/null; }
setst() { echo "$2" > "$cd_dir/$1.state"; ev "$1 -> $2${3:+ ($3)}"; }
num() { cat "$cd_dir/$1.$2" 2>/dev/null || echo 0; }
inc() { echo $(( $(num "$1" "$2") + 1 )) > "$cd_dir/$1.$2"; }
started_of() { cat "$crew/lanes/$1.started" 2>/dev/null || echo 0; }
lane_st() { cat "$crew/lanes/$1.status" 2>/dev/null || echo none; }
alive() { case "$(lane_st "$1")" in running|waking) return 0;; esac; return 1; }
exited_since_launch() { # the lane finished a run that started at or after our launch stamp (0 = adopted: any finished run counts)
  local ls; alive "$1" && return 1; ls=$(num "$1" launched); [ "$ls" -eq 0 ] && return 0; [ "$(started_of "$1")" -ge "$ls" ]
}
digest() {
  echo "--- crew digest"
  for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; l=$(basename "$f" .status)
    printf '%-12s lane=%-22s conductor=%-9s fixes=%s reviews=%s\n' "$l" "$(lane_st "$l")" "$(st_of "$l")" "$(num "$l" fix)" "$(num "$l" rev)"; done
  bash "$here/crew-budget.sh" "$proj" check | head -1
}
finish_run() { echo "CONDUCT $*"; digest; ev "exit: $*"; exit 0; }

launch() { # launch <lane> <brief> [role]: detached; records the launch stamp; a refusal becomes a BRAIN state
  local lane=$1 brief=$2 role=${3:-} out="$crew/logs/$1-launch.out"
  date +%s > "$cd_dir/$lane.launched"; : > "$out"
  CREW_ROLE=$role bash "$here/crew-launch.sh" "$proj" lane "$lane" - "$brief" >/dev/null 2>&1
  for _ in $(seq 1 40); do alive "$lane" && break; [ "$(started_of "$lane")" -ge "$(num "$lane" launched)" ] && break; sleep 0.2; done
  if ! alive "$lane" && [ "$(started_of "$lane")" -lt "$(num "$lane" launched)" ]; then
    setst "$lane" brain "launch refused"; echo "launch refused: $(head -c 300 "$out" | tr '\n' ' ')" > "$cd_dir/$lane.brain"; return 1; fi
  setst "$lane" launched "$(basename "$brief")"; return 0
}
fix_lane() { # fix_lane <lane> <kind> <text>: resume the lane with a correction brief, bounded rounds
  local lane=$1 kind=$2 text=$3 n f
  if [ "$(num "$lane" fix)" -ge "$autofix" ]; then setst "$lane" brain "fix rounds exhausted"; printf 'fix rounds exhausted (%s). Last problem:\n%s\n' "$autofix" "$text" > "$cd_dir/$lane.brain"; return 1; fi
  inc "$lane" fix; n=$(num "$lane" fix); f="$crew/prompts/$lane-fix-$n.md"
  printf 'Your work was checked automatically and needs fixes (%s). Fix ONLY what is listed, re-run your acceptance command, re-read CONTRACTS.md, then post a new DONE line in the exact format.\n\n%s\n' "$kind" "$text" > "$f"
  launch "$lane" "$f"
}
merge_lane() {
  local lane=$1 m rc
  if [ "$domerge" = 1 ] && [ -f "$crew/lanes/$lane.workdir" ]; then
    m=$(bash "$here/crew-worktree.sh" "$proj" merge "$lane" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$m" | grep -q 'NOT merged (outside its scope)'; then setst "$lane" brain "merge problem"; printf '%s\n' "$m" | head -12 > "$cd_dir/$lane.brain"; return 1; fi
    ev "$lane merged: $(printf '%s' "$m" | head -1)"
  fi
  bash "$here/crew-tasks.sh" "$proj" lane "$lane" review "done"   # tasks with no acceptance command stay 'review' otherwise
  setst "$lane" merged
}
after_clean() { # a clean lane: have it reviewed (read-only Devin) or merge it
  local lane=$1
  if [ "$autorev" = 1 ] && [ "$(num "$lane" rev)" -lt "$passes" ]; then
    inc "$lane" rev; setst "$lane" reviewing; date +%s > "$cd_dir/$lane-rev.launched"
    bash "$here/crew-review.sh" "$proj" "$lane" >/dev/null 2>&1; return 0
  fi
  merge_lane "$lane"
}
skip_review() { ev "$1 review skipped: $2"; echo "REVIEW-SKIPPED $1 ($2)" >> "$cd_dir/notes"; merge_lane "$1"; }

case "${1:-}" in
  --status) digest; exit 0;;
  --reset) l=${2:?lane}; setst "$l" "${3:-launched}"; rm -f "${cd_dir:?}/${l:?}.brain" "${cd_dir:?}/${l:?}.reported"; [ "${3:-launched}" = launched ] && echo 0 > "$cd_dir/$l.launched"; echo "reset $l"; exit 0;;
esac

ev "start (autofix=$autofix autoreview=$autorev merge=$domerge lanes<=$maxlanes)"
t0=$(date +%s)
while :; do
  [ $(( $(date +%s) - t0 )) -ge "$maxsecs" ] && finish_run TIMEOUT
  # 1. things that are never the conductor's to handle
  for nu in "$crew"/lanes/*.needs-user; do [ -e "$nu" ] || continue; l=$(basename "$nu" .needs-user)
    finish_run "NEEDS-USER $l $(head -1 "$nu")"; done
  om=$(bash "$here/lane-msg.sh" "$proj" pending | awk '$1=="orchestrator"{print $3}'); [ -n "$om" ] && [ "$om" -gt 0 ] && finish_run "ORCHESTRATOR-MAIL $om"
  bash "$here/crew-budget.sh" "$proj" check >/dev/null 2>&1; [ $? -eq 2 ] && finish_run BUDGET
  # 2. adopt lanes the brain launched by hand (task running/review/failed, no conductor state)
  for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; l=$(basename "$f" .status); case "$l" in *-rev) continue;; esac
    [ -f "$cd_dir/$l.state" ] && continue
    awk -F'|' -v l="$l" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 && t($3)==l {s=(t($NF)=="")?NF-1:NF; if (t($s)=="review"||t($s)=="running"||t($s)=="failed") f=1} END{exit f?0:1}' "$crew/TASKS.md" 2>/dev/null \
      && { echo 0 > "$cd_dir/$l.launched"; setst "$l" launched "adopted"; }
  done
  # 3. collect exited lanes and their reviewers
  for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; l=$(basename "$f" .status); case "$l" in *-rev) continue;; esac
    case "$(st_of "$l")" in
      launched)
        exited_since_launch "$l" || continue
        out=$(bash "$here/crew-collect.sh" "$proj" "$l" 2>&1); rc=$?
        case "$rc" in
          0) after_clean "$l";;
          1) fix_lane "$l" "acceptance/contract" "$(printf '%s\n' "$out" | grep -v '^VERDICT' | head -30)";;
          3) ;;
          *) setst "$l" brain "$(printf '%s' "$out" | grep '^VERDICT' | head -1)"; printf '%s\n' "$out" | head -30 > "$cd_dir/$l.brain";;
        esac;;
      reviewing)
        r="$l-rev"; alive "$r" && continue
        if [ "$(started_of "$r")" -lt "$(num "$r" launched)" ]; then   # reviewer has not started (or was refused)
          [ $(( $(date +%s) - $(num "$r" launched) )) -gt 60 ] && skip_review "$l" "reviewer never started"; continue; fi
        [ "$(lane_st "$r")" != "done" ] && { skip_review "$l" "reviewer $(lane_st "$r")"; continue; }
        fnd=$(bash "$here/crew-review.sh" "$proj" "$l" --findings 2>&1); rc=$?
        case "$rc" in
          0) merge_lane "$l";;
          3) skip_review "$l" "no findings file";;
          *) fix_lane "$l" "reviewer findings" "$fnd";;
        esac;;
    esac
  done
  # 4. a lane needing the brain ends the run (other lanes keep running detached)
  for f in "$cd_dir"/*.state; do [ -e "$f" ] || continue; l=$(basename "$f" .state)
    if [ "$(cat "$f")" = brain ] && [ ! -f "$cd_dir/$l.reported" ]; then
      touch "$cd_dir/$l.reported"; echo "--- $l"; cat "$cd_dir/$l.brain" 2>/dev/null
      finish_run "BRAIN $l: $(head -1 "$cd_dir/$l.brain" 2>/dev/null | cut -c1-160)"; fi
  done
  # 5. launch every ready task in parallel, up to the lane cap
  running=0; for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; alive "$(basename "$f" .status)" && running=$((running + 1)); done
  nobrief=""; launched_now=0
  while read -r id lane; do
    [ -z "$id" ] && continue
    case "$(st_of "$lane")" in brain|launched|reviewing) continue;; esac
    [ "$running" -ge "$maxlanes" ] && break
    if [ ! -s "$crew/prompts/$id.md" ]; then nobrief="$nobrief $id"; continue; fi
    role=implementer; [ -s "$crew/prompts/$id.role" ] && role=$(head -1 "$crew/prompts/$id.role")
    echo 0 > "$cd_dir/$lane.fix"; echo 0 > "$cd_dir/$lane.rev"
    launch "$lane" "$crew/prompts/$id.md" "$role" && { running=$((running + 1)); launched_now=1; }
  done < <(bash "$here/crew-tasks.sh" "$proj" next)
  # 6. finished, or stuck?
  active=0; for f in "$cd_dir"/*.state; do [ -e "$f" ] || continue; case "$(cat "$f")" in launched|reviewing) active=1;; esac; done
  for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; alive "$(basename "$f" .status)" && active=1; done
  if [ "$active" -eq 0 ] && [ "$launched_now" -eq 0 ]; then
    left=$(awk -F'|' 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 {id=t($2); if(id=="id"||id==""||id ~ /^-/||id ~ /^:/) next; s=(t($NF)=="")?NF-1:NF; if (t($s)!="done") printf "%s ", id}' "$crew/TASKS.md" 2>/dev/null)
    if [ -z "$left" ]; then [ -s "$cd_dir/notes" ] && cat "$cd_dir/notes"; finish_run MILESTONE-READY; fi
    finish_run "STUCK ${left}${nobrief:+(no brief for:$nobrief)}"
  fi
  sleep "$poll"
done
