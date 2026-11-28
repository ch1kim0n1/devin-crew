#!/usr/bin/env bash
# Run an approved plan to the end with no brain in the loop: milestones, QA, fix rounds, final QA, report, branch + PR.
#   bash crew-autopilot.sh <project> --detach     start it in the background (survives the brain's session); prints pid and log
#   bash crew-autopilot.sh <project> run          run in the foreground (what --detach runs)
#   bash crew-autopilot.sh <project> --wait       block until DONE / ATTENTION / stopped, then print the status (run it as a background task: that is the brain's one wake-up)
#   bash crew-autopilot.sh <project> --status     one short summary: running?, milestone, QA rounds, attention/done
#   bash crew-autopilot.sh <project> --stop       stop the autopilot (running lanes keep going; the conductor is rerunnable)
# Inputs (written by the planner / brain before the go): TASKS.md (header, rows of milestone 1 may already be in it), scopes.txt for every lane,
# prompts/<task>.md briefs, and optionally milestones/m<N>.tasks (TASKS rows of milestone N; a first line `# name` names it). Without milestone
# files the TASKS.md rows are one milestone.
# Loop: conductor -> MILESTONE-READY (QA passed) -> commit (if shipping is authorized) -> next milestone -> ... -> final whole-objective QA when
# there was more than one milestone -> reporter -> push + PR. QA-FAIL: its FIXTASK lines become tasks with briefs, up to CREW_QA_ROUNDS (3)
# per milestone, stopping if the same failure comes back. Anything else (NEEDS-USER, BRAIN, ORCHESTRATOR-MAIL, BUDGET, STUCK) stops the
# autopilot, writes .devin-crew/autopilot/ATTENTION with the digest and sends a desktop notification; fix it, then run --detach again
# (the state is in files, so it continues where it stopped).
# Per-task shipping (`ship: per-task`): the conductor opens one PR per task; PR-WAIT stops me (ATTENTION) until a PR is reviewed or merged.
# env: CREW_QA_ROUNDS=3 | CREW_AUTOPILOT_MAX_SECS=21600 | CREW_SHIP_OK=1 or `ship: yes` in PLAN.md authorizes branch + PR (without it the run ends at REPORT.md)
set -u
proj=$(cd "$1" && pwd -P) || exit 2
mode=${2:-run}; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; ap="$crew/autopilot"
mkdir -p "$ap" "$crew/milestones" "$crew/acceptance" "$crew/prompts"
maxrounds=${CREW_QA_ROUNDS:-3}; maxsecs=${CREW_AUTOPILOT_MAX_SECS:-21600}
log() { echo "$(date '+%F %T') autopilot $*" >> "$crew/events.log"; echo "$(date '+%F %T') $*" >> "$ap/log"; }
get() { cat "$ap/$1" 2>/dev/null || echo "${2:-}"; }
alive_pid() { local p; p=$(cat "$ap/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
case "$mode" in
  --detach)
    alive_pid && { echo "autopilot already running (pid $(cat "$ap/pid"))"; exit 0; }
    rm -f "$ap/ATTENTION"; nohup bash "$0" "$proj" run >> "$ap/out.log" 2>&1 </dev/null &
    echo $! > "$ap/pid"; echo "autopilot started pid $! (log: $ap/log; summary: bash $0 $proj --status)"; exit 0;;
  --wait)   # block until the run ends (DONE, ATTENTION, or the process is gone); for a background task that wakes the brain once
    while :; do [ -f "$ap/DONE" ] || [ -f "$ap/ATTENTION" ] && break; alive_pid || break; sleep "${CREW_AUTOPILOT_WAIT_POLL:-20}"; done
    bash "$0" "$proj" --status; exit 0;;
  --stop) alive_pid && { kill "$(cat "$ap/pid")"; echo "autopilot stopped"; } || echo "autopilot not running"; rm -f "$ap/pid"; exit 0;;
  --status)
    st=stopped; alive_pid && st=running; [ -f "$ap/DONE" ] && st=DONE; [ -f "$ap/ATTENTION" ] && st=ATTENTION
    echo "autopilot: $st | milestone $(get current none) (loaded: $(get loaded none | tr '\n' ' ')) | QA fix rounds this milestone: $(get rounds 0) | final QA: $(get final no)"
    [ -f "$ap/DONE" ] && cat "$ap/DONE"; [ -f "$ap/ATTENTION" ] && head -12 "$ap/ATTENTION"
    tail -3 "$ap/log" 2>/dev/null | sed 's/^/  /'; exit 0;;
  run) ;;
  *) sed -n 2,6p "$0"; exit 2;;
esac

trim() { local x=$1; x=${x#"${x%%[![:space:]]*}"}; echo "${x%"${x##*[![:space:]]}"}"; }
notify() { bash "$here/crew-notify.sh" "devin-crew: $*" >/dev/null 2>&1; }
attention() { { echo "$1"; cat "$ap/last.digest" 2>/dev/null; } > "$ap/ATTENTION"; log "ATTENTION: $1"; notify "$1"; echo "ATTENTION: $1"; exit 0; }
authorized() { [ "${CREW_SHIP_OK:-0}" = 1 ] || grep -qiE '^ship: *(yes|per-task)' "$crew/PLAN.md" 2>/dev/null; }
per_task() { bash "$here/crew-pr.sh" "$proj" mode; }
git_root() { [ "$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" = "$proj" ]; }
refresh_lane_on_launch() { # the conductor prepares the worktree before launching the lane
  local l=$1 st; st=$(cat "$crew/lanes/$l.status" 2>/dev/null || echo none)
  git_root || return 0
  case "$st" in running|waking) return 0;; esac
  mkdir -p "$crew/conduct" && touch "$crew/conduct/$l.refresh-worktree" ||
    attention "WORKTREE $l: could not queue a worktree refresh"
}
lanes_of_rows() { awk -F'|' 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 {id=t($2); if(id=="id"||id==""||id ~ /^-/||id ~ /^:/) next; print t($3)}' "$1" | sort -u; }
ms_files() { ls "$crew"/milestones/m*.tasks 2>/dev/null | sed -E 's#.*/m([0-9]+)\.tasks#\1#' | sort -n; }
load_next_ms() { # appends the next unloaded milestone's rows to TASKS.md; prints its number, or nothing when none is left
  local n f name
  for n in $(ms_files); do grep -qx "$n" "$ap/loaded" 2>/dev/null && continue
    f="$crew/milestones/m$n.tasks"; name=$(sed -n 's/^# *//p' "$f" | head -1)
    for l in $(lanes_of_rows "$f"); do refresh_lane_on_launch "$l"; bash "$here/crew-conduct.sh" "$proj" --reset "$l" merged >/dev/null 2>&1; done
    [ -f "$crew/TASKS.md" ] || printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n' > "$crew/TASKS.md"
    grep -E '^\|' "$f" | grep -vE '^\| *(id|-)' >> "$crew/TASKS.md"
    echo "$n" >> "$ap/loaded"; echo "$n" > "$ap/current"; echo 0 > "$ap/rounds"; : > "$ap/lastsig"
    echo "M$n${name:+: $name}" > "$crew/MILESTONE"; rm -f "$crew/conduct/qa.state"; log "loaded milestone $n ${name:+($name)}"; echo "$n"; return 0; done
  return 1
}
fix_tasks() { # QA-FAIL: FIXTASK lines of the newest verdict -> task rows, briefs, scopes, acceptance scripts
  local v k=0 line p n lane files goal acc id r m; v=$(bash "$here/crew-audit.sh" "$proj" path 2>/dev/null)
  [ -s "$v" ] || return 1
  r=$(( $(get rounds 0) + 1 )); m=$(get current 1)
  while IFS= read -r line; do case "$line" in FIXTASK:*) ;; *) continue;; esac
    IFS='|' read -r -a p <<< "${line#FIXTASK:}"; n=${#p[@]}; [ "$n" -ge 4 ] || continue
    k=$((k + 1)); lane=$(trim "${p[0]}"); files=$(trim "${p[1]}"); goal=$(trim "${p[$((n - 1))]}")
    acc=""; for ((i = 2; i < n - 1; i++)); do acc="${acc:+$acc|}${p[$i]}"; done; acc=$(trim "$acc")
    id="fix${m}r${r}-$k"
    if [ "$lane" = new ] || [ -z "$lane" ] || ! grep -q "^$lane	" "$crew/scopes.txt" 2>/dev/null; then lane="fix${m}r${r}-$k"; fi
    refresh_lane_on_launch "$lane"
    [ -n "$(tail -c1 "$crew/scopes.txt" 2>/dev/null)" ] && echo >> "$crew/scopes.txt"
    for g in $(printf '%s' "$files" | tr ',' ' '); do printf '%s\t%s\n' "$lane" "$g" >> "$crew/scopes.txt"; done
    printf '%s\n' "$acc" > "$crew/acceptance/$id.sh"
    printf '| %s | %s | %s | - | bash %s | open |\n' "$id" "$lane" "$(printf '%s' "$files" | tr ',' ' ')" "$crew/acceptance/$id.sh" >> "$crew/TASKS.md"
    printf 'The QA Devin failed the milestone. Fix exactly this: %s\nFiles you own for this: %s\nAcceptance (must pass): %s\nFull QA verdict, for context: %s\nRead %s first. Change nothing else.\n' "$goal" "$files" "$acc" "$v" "$crew/CONTRACTS.md" > "$crew/prompts/$id.md"
    bash "$here/crew-conduct.sh" "$proj" --reset "$lane" merged >/dev/null 2>&1
  done < "$v"
  [ "$k" -gt 0 ] || return 1
  echo "$r" > "$ap/rounds"; log "QA-FAIL round $r: $k fix task(s) from $(basename "$v")"; return 0
}

t0=$(date +%s); log "start (rounds<=$maxrounds, ship=$(authorized && echo yes || echo no))"
if ! { [ "$(cat "$crew/router.pid" 2>/dev/null)" ] && kill -0 "$(cat "$crew/router.pid")" 2>/dev/null; }; then bash "$here/crew-launch.sh" "$proj" router >/dev/null 2>&1; fi
nms=$(ms_files | wc -l | tr -d ' ')
[ "$nms" -gt 0 ] && [ -z "$(get loaded)" ] && load_next_ms >/dev/null
while :; do
  [ $(( $(date +%s) - t0 )) -ge "$maxsecs" ] && attention "autopilot time cap reached ($maxsecs s)"
  bash "$here/crew-conduct.sh" "$proj" > "$ap/last.digest" 2>&1
  reason=$(grep -m1 '^CONDUCT ' "$ap/last.digest" | sed 's/^CONDUCT //'); log "conductor: ${reason:-no digest}"
  case "$reason" in
    TIMEOUT*) continue;;
    MILESTONE-READY*)
      if authorized && ! per_task; then c=$(bash "$here/crew-ship.sh" "$proj" commit "$(cat "$crew/MILESTONE" 2>/dev/null || echo milestone)" 2>&1 | tail -1); log "commit: $c"; fi
      if load_next_ms >/dev/null; then continue; fi
      if [ "$nms" -gt 1 ] && [ "$(get final no)" = no ]; then   # one more QA over the whole objective
        echo yes > "$ap/final"; echo "FINAL: whole objective, all milestones together" > "$crew/MILESTONE"; rm -f "$crew/conduct/qa.state"; log "final whole-objective QA"; continue; fi
      bash "$here/crew-conduct.sh" "$proj" --report > "$ap/report.out" 2>&1; log "report: $(head -1 "$ap/report.out")"
      if per_task; then s="per-task PRs, all merged: $(cat "$crew"/pr/*.url 2>/dev/null | tr '\n' ' ')"; log "ship: $s"
      elif authorized; then s=$(bash "$here/crew-ship.sh" "$proj" all 2>&1 | tail -1); log "ship: $s"; else s="not authorized to push: branch/PR skipped (REPORT.md is ready)"; fi
      { echo "DONE $(date '+%F %T')"; echo "$s"; head -20 "$crew/REPORT.md" 2>/dev/null; } > "$ap/DONE"; notify "run finished. $s"; echo "DONE: $s"; exit 0;;
    QA-FAIL*)
      r=$(get rounds 0); [ "$r" -ge "$maxrounds" ] && attention "QA still failing after $maxrounds fix rounds (milestone $(get current 1))"
      sig=$(grep '^FIXTASK' "$ap/last.digest" | cksum | cut -d' ' -f1); [ "$sig" = "$(get lastsig)" ] && [ -n "$sig" ] && attention "QA found the same failures again after a fix round: needs a decision"
      echo "$sig" > "$ap/lastsig"
      fix_tasks || attention "QA failed but its verdict has no usable FIXTASK lines: needs a decision";;
    *) attention "${reason:-conductor gave no digest}";;
  esac
done
