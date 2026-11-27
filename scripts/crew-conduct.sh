#!/usr/bin/env bash
# Conductor: runs the crew's routine loop WITHOUT the brain, so the brain wakes once per decision instead of once per step.
# Run me with Bash run_in_background=true. I launch every ready task in parallel (up to CREW_CONDUCT_MAX_LANES), and when a lane exits I
# collect it (acceptance, scope, contract), resume it with the printed failures if it can fix them, launch a read-only reviewer Devin,
# resume the lane with the review findings, and merge it when clean. I exit with ONE digest only when the brain is needed.
#   bash crew-conduct.sh <project>                 run until a reason below
#   bash crew-conduct.sh <project> --status        lane states, no side effects
#   bash crew-conduct.sh <project> --reset <lane> [state]   clear a lane's BRAIN state after you handled it (default state: launched = re-collect)
# Needs per task: .devin-crew/prompts/<task-id>.md (the brief); optional <task-id>.role (a file name in templates/roles/), default: picked from the
# task's scope globs by crew-roles.sh (backend, frontend, mobile, database, devops, tests, docs, else implementer).
# Final line (exit 0), one of:
#   CONDUCT MILESTONE-READY            every task done, every lane merged, and (CREW_AUTOQA=1) a QA Devin passed: the verdict is printed
#   CONDUCT QA-FAIL                    the QA Devin failed the milestone: its findings and FIXTASK lines are printed; turn them into tasks
#   CONDUCT BRAIN <lane>: <why>        needs judgment (scope breach, merge conflict, fixes exhausted, lane failed, launch refused)
#   CONDUCT NEEDS-USER <lane> <class>  Devin error: tell the user, retry only on their word (CREW_RETRY_OK=1)
#   CONDUCT ORCHESTRATOR-MAIL <n>      a lane mailed you
#   CONDUCT BUDGET                     lane-minute budget exceeded
#   CONDUCT STUCK <ids>                open tasks cannot launch (no brief, or dependencies not done)
#   CONDUCT TIMEOUT
# A digest that is the Nth wake of this run (CREW_FRESH_AFTER, default 12) also prints FRESH-SESSION: the brain's context is the cost, so
# finish the decision, keep PLAN.md current and continue in a new session (/devin-crew resume).
#   bash crew-conduct.sh <project> --report        launch the reporter Devin, wait for it, print the head of .devin-crew/REPORT.md
# env: CREW_AUTOFIX=2 fix rounds per lane | CREW_AUTOREVIEW=1 (0 off) | CREW_REVIEW_PASSES=2 | CREW_MERGE=1 (worktree lanes) |
#      CREW_AUTOQA=1 (0 off: the brain runs QA itself, expensive) | CREW_FRESH_AFTER=12 | CREW_CONDUCT_MAX_LANES=5 | CREW_CONDUCT_POLL=10 | CREW_CONDUCT_MAX_SECS=7200
set -u
proj=$(cd "$1" && pwd -P) || exit 2
shift; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; cd_dir="$crew/conduct"; mkdir -p "$cd_dir" "$crew/prompts" "$crew/lanes" "$crew/logs"
autofix=${CREW_AUTOFIX:-2}; autorev=${CREW_AUTOREVIEW:-1}; passes=${CREW_REVIEW_PASSES:-2}; domerge=${CREW_MERGE:-1}
autoqa=${CREW_AUTOQA:-1}; fresh_after=${CREW_FRESH_AFTER:-12}
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
finish_run() { # the one place the brain is woken: count wakes, and say when the session should be renewed
  local w; w=$(( $(cat "$cd_dir/wakes" 2>/dev/null || echo 0) + 1 )); echo "$w" > "$cd_dir/wakes"
  echo "CONDUCT $*"; digest
  [ "$w" -ge "$fresh_after" ] && echo "FRESH-SESSION: $w brain wakes in this run. Handle this one, bring PLAN.md up to date, then tell the user to continue in a new session with /devin-crew resume (every call re-reads the whole history)."
  ev "exit: $*"; exit 0; }

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
race_partner() { local f a b; for f in "$crew"/race/*; do [ -e "$f" ] || continue; read -r a b < "$f"; [ "$a" = "$1" ] && { echo "$b"; return 0; }; [ "$b" = "$1" ] && { echo "$a"; return 0; }; done; return 1; }
race_score() { # lower is better: reviewer findings weigh most, then the size of the diff
  local l=$1 h m lo wd ch=0; h=$(grep -ciE '\(high\)|: high' "$crew/reviews/$l.md" 2>/dev/null); m=$(grep -ciE '\(med\)|: med' "$crew/reviews/$l.md" 2>/dev/null); lo=$(grep -ciE '\(low\)|: low' "$crew/reviews/$l.md" 2>/dev/null)
  wd=$(cat "$crew/lanes/$l.workdir" 2>/dev/null); [ -n "$wd" ] && ch=$(git -C "$wd" diff HEAD --numstat 2>/dev/null | awk '{n+=$1+$2} END{print n+0}')
  echo $(( ${h:-0} * 100000 + ${m:-0} * 10000 + ${lo:-0} * 1000 + ${ch:-0} ))
}
merge_lane() { # best-of-2 lanes wait for their twin; everything else merges at once
  local lane=$1 p w l sa sb
  if p=$(race_partner "$lane"); then
    setst "$lane" raced
    case "$(st_of "$p")" in
      raced) sa=$(race_score "$lane"); sb=$(race_score "$p")
             if [ "$sb" -lt "$sa" ]; then w=$p; l=$lane; else w=$lane; l=$p; fi
             setst "$l" discarded "lost the race to $w ($sa vs $sb)"; bash "$here/crew-tasks.sh" "$proj" lane "$l" "review|running|failed|open" "done"
             bash "$here/crew-worktree.sh" "$proj" remove "$l" >/dev/null 2>&1; echo "RACE-WON $w over $l" >> "$cd_dir/notes"
             do_merge_lane "$w"; return;;
      brain|discarded) do_merge_lane "$lane"; return;;
      *) return 0;;
    esac
  fi
  do_merge_lane "$lane"
}
do_merge_lane() {
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
qa_gate() { # all tasks done: have a QA Devin verify the milestone. Returns 0 = passed (fall through to MILESTONE-READY), 1 = keep waiting; exits the run on FAIL.
  local qs ql v rc
  qs=$(cat "$cd_dir/qa.state" 2>/dev/null)
  case "$qs" in
    passed) return 0;;
    running)
      ql=$(cat "$crew/qa/lane" 2>/dev/null)
      if [ -z "$ql" ] || [ "$(started_of "$ql")" -lt "$(num qa launched)" ]; then   # QA Devin has not started (or was refused)
        [ $(( $(date +%s) - $(num qa launched) )) -gt 120 ] && { echo failed > "$cd_dir/qa.state"; finish_run "BRAIN qa: the QA Devin never started ($(head -c 200 "$crew/logs/$ql-launch.out" 2>/dev/null | tr '\n' ' '))"; }
        return 1; fi
      alive "$ql" && return 1
      v=$(bash "$here/crew-audit.sh" "$proj" verdict 2>&1); rc=$?
      printf '%s\n' "$v"
      case "$rc" in
        0) echo passed > "$cd_dir/qa.state"; ev "qa passed: $(printf '%s' "$v" | head -1)"; return 0;;
        1) echo failed > "$cd_dir/qa.state"; finish_run "QA-FAIL $(printf '%s' "$v" | head -1 | cut -c1-120)";;
        *) echo failed > "$cd_dir/qa.state"; finish_run "BRAIN qa: no usable verdict from $ql (see $crew/logs)";;
      esac;;
    specs)   # specialist reviewers (security, a11y, performance) run first and in parallel; the QA Devin folds their findings in
      for sl in $(cat "$crew/qa/specialist-lanes" 2>/dev/null); do
        alive "$sl" && return 1
        [ "$(started_of "$sl")" -lt "$(num qa launched)" ] && [ $(( $(date +%s) - $(num qa launched) )) -lt 120 ] && return 1
      done
      date +%s > "$cd_dir/qa.launched"; echo running > "$cd_dir/qa.state"; bash "$here/crew-audit.sh" "$proj" qa >/dev/null 2>&1; ev "qa launched: $(cat "$crew/qa/lane" 2>/dev/null)"; return 1;;
    *) date +%s > "$cd_dir/qa.launched"
       if [ -n "$(bash "$here/crew-audit.sh" "$proj" specialists 2>/dev/null)" ]; then echo specs > "$cd_dir/qa.state"; ev "specialists launched: $(cat "$crew/qa/specialist-lanes" 2>/dev/null)"; return 1; fi
       echo running > "$cd_dir/qa.state"; bash "$here/crew-audit.sh" "$proj" qa >/dev/null 2>&1; ev "qa launched: $(cat "$crew/qa/lane" 2>/dev/null)"; return 1;;
  esac
}
has_wt() { [ -f "$crew/lanes/$1.workdir" ] && [ "$(cat "$crew/lanes/$1.workdir")" != "$proj" ]; }
siblings_pending() { # another lane is still working or waiting to be collected/merged: its code may be what this lane's acceptance needs
  local f o; for f in "$cd_dir"/*.state; do [ -e "$f" ] || continue; o=$(basename "$f" .state); [ "$o" = "$1" ] && continue
    case "$(cat "$f")" in launched|reviewing) return 0;; esac; done; return 1; }
skip_review() { ev "$1 review skipped: $2"; echo "REVIEW-SKIPPED $1 ($2)" >> "$cd_dir/notes"; merge_lane "$1"; }

case "${1:-}" in
  --status) digest; exit 0;;
  --report)
    t1=$(date +%s); bash "$here/crew-audit.sh" "$proj" report >/dev/null 2>&1
    while :; do { alive report || [ "$(started_of report)" -lt "$t1" ]; } || break
      [ $(( $(date +%s) - t1 )) -ge "$maxsecs" ] && { echo "CONDUCT TIMEOUT (reporter)"; exit 0; }; sleep "$poll"; done
    if [ -s "$crew/REPORT.md" ]; then echo "CONDUCT REPORT-READY"; head -50 "$crew/REPORT.md"; else echo "CONDUCT BRAIN report: the reporter wrote no REPORT.md (see $crew/logs/report-launch.out)"; fi
    exit 0;;
  --reset) l=${2:?lane}; setst "$l" "${3:-launched}"; rm -f "${cd_dir:?}/${l:?}.brain" "${cd_dir:?}/${l:?}.reported"; [ "${3:-launched}" = launched ] && echo 0 > "$cd_dir/$l.launched"; echo "reset $l (conductor state only: a failed lane stays failed and tasks keep their status; to recover and relaunch it use crew-lane-reset.sh)"; exit 0;;
esac

ev "start (autofix=$autofix autoreview=$autorev merge=$domerge lanes<=$maxlanes)"
t0=$(date +%s)
while :; do
  [ $(( $(date +%s) - t0 )) -ge "$maxsecs" ] && finish_run TIMEOUT
  # 1. things that are never the conductor's to handle
  for nu in "$crew"/lanes/*.needs-user; do [ -e "$nu" ] || continue; l=$(basename "$nu" .needs-user)
    finish_run "NEEDS-USER $l $(head -1 "$nu")"; done
  # Mail for the orchestrator: questions and BLOCKED end the run (printed in full); notes and reports are logged.
  om=$(bash "$here/lane-msg.sh" "$proj" pending | awk '$1=="orchestrator"{print $3}')
  if [ -n "$om" ] && [ "$om" -gt 0 ]; then
    msgs=$(bash "$here/lane-msg.sh" "$proj" read orchestrator)
    # Only a question (contains '?') or a BLOCKED lane wakes the brain; progress reports and notes go to conduct/notes and the final digest.
    if printf '%s\n' "$msgs" | grep -qE '\?|BLOCKED'; then printf '%s\n' "$msgs" | cut -c1-500; finish_run "ORCHESTRATOR-MAIL $om"
    else printf '%s\n' "$msgs" | cut -c1-400 >> "$cd_dir/notes"; ev "orchestrator: $om note(s) logged"; fi
  fi
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
        # A worktree lane never sees its siblings' code (a test-first tests lane imports what impl writes): its acceptance can fail for a reason
        # no fix round can cure. Wait until the siblings are merged, copy their work into its worktree, collect again, and only then fix.
        if [ "$rc" -eq 1 ] && has_wt "$l"; then
          if siblings_pending "$l"; then setst "$l" waiting "acceptance failed; waiting for sibling lanes to merge"; continue; fi
          n=$(bash "$here/crew-worktree.sh" "$proj" sync "$l" 2>/dev/null | tail -1)
          case "$n" in ''|*[!0-9]*|0) ;; *) ev "$l: synced $n file(s) of merged sibling work into its worktree; collecting again"; out=$(bash "$here/crew-collect.sh" "$proj" "$l" 2>&1); rc=$?;; esac
        fi
        case "$rc" in
          0) after_clean "$l";;
          1) fix_lane "$l" "acceptance/contract" "$(printf '%s\n' "$out" | grep -v '^VERDICT' | head -30)";;
          3) ;;
          *) setst "$l" brain "$(printf '%s' "$out" | grep '^VERDICT' | head -1)"; printf '%s\n' "$out" | head -30 > "$cd_dir/$l.brain";;
        esac;;
      waiting) siblings_pending "$l" || setst "$l" launched "siblings merged, collecting again";;
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
  for f in "$cd_dir"/*.state; do [ -e "$f" ] || continue; l=$(basename "$f" .state); [ "$(cat "$f")" = raced ] || continue
    p=$(race_partner "$l") && case "$(st_of "$p")" in brain|discarded) ev "$l: twin $p ended without a result, merging $l"; do_merge_lane "$l";; esac
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
    case "$(st_of "$lane")" in brain|launched|reviewing|waiting) continue;; esac
    [ "$running" -ge "$maxlanes" ] && break
    if [ ! -s "$crew/prompts/$id.md" ]; then nobrief="$nobrief $id"; continue; fi
    if [ -s "$crew/prompts/$id.role" ]; then role=$(head -1 "$crew/prompts/$id.role"); else role=$(bash "$here/crew-roles.sh" pick "$proj" "$id" 2>/dev/null); fi   # the team member that fits the files
    [ -f "$here/../templates/roles/${role:-x}.md" ] || role=implementer
    echo 0 > "$cd_dir/$lane.fix"; echo 0 > "$cd_dir/$lane.rev"
    # Later waves and fix rounds need a worktree cut from the current merged tree.
    refresh="$cd_dir/$lane.refresh-worktree"
    isolated=0
    if [ -f "$crew/worktree-required" ] || { [ ! -f "$crew/snapshot.stamp" ] &&
      { [ -d "$crew/wt" ] || { ls "$crew"/lanes/*.workdir >/dev/null 2>&1 &&
        [ "$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" = "$proj" ]; }; }; }; then
      isolated=1
    fi
    if [ -f "$refresh" ] || { [ "$isolated" = 1 ] && [ ! -s "$crew/lanes/$lane.workdir" ]; }; then
      if [ -f "$refresh" ] && [ -d "$crew/wt/$lane" ]; then
        if ! output=$(bash "$here/crew-worktree.sh" "$proj" remove "$lane" 2>&1); then
          printf '%s\n' "$output"
          finish_run "WORKTREE $lane: could not refresh the existing worktree"
        fi
      fi
      if ! output=$(bash "$here/crew-worktree.sh" "$proj" add "$lane" 2>&1); then
        printf '%s\n' "$output"
        finish_run "WORKTREE $lane: could not prepare an isolated worktree"
      fi
      rm -f "$refresh"
      ev "$lane: worktree created from the merged tree"
    fi
    launch "$lane" "$crew/prompts/$id.md" "$role" && { running=$((running + 1)); launched_now=1; rm -f "$cd_dir/qa.state"; }
  done < <(bash "$here/crew-tasks.sh" "$proj" next)
  # 6. finished, or stuck?
  active=0; for f in "$cd_dir"/*.state; do [ -e "$f" ] || continue; case "$(cat "$f")" in launched|reviewing|waiting) active=1;; esac; done
  for f in "$crew"/lanes/*.status; do [ -e "$f" ] || continue; alive "$(basename "$f" .status)" && active=1; done
  if [ "$active" -eq 0 ] && [ "$launched_now" -eq 0 ]; then
    left=$(awk -F'|' 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 {id=t($2); if(id=="id"||id==""||id ~ /^-/||id ~ /^:/) next; s=(t($NF)=="")?NF-1:NF; if (t($s)!="done") printf "%s ", id}' "$crew/TASKS.md" 2>/dev/null)
    if [ -z "$left" ]; then
      if [ "$autoqa" = 1 ]; then qa_gate || { sleep "$poll"; continue; }; fi
      [ -s "$cd_dir/notes" ] && cat "$cd_dir/notes"; finish_run MILESTONE-READY; fi
    finish_run "STUCK ${left}${nobrief:+(no brief for:$nobrief)}"
  fi
  sleep "$poll"
done
