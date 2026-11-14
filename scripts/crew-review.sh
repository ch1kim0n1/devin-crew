#!/usr/bin/env bash
# Launch a read-only reviewer Devin on a finished lane's work, so the brain reads a short findings file instead of the diff.
#   bash crew-review.sh <project> <lane> [--print]
# Creates lane "<lane>-rev" that works inside the lane's worktree (or the shared tree), role reviewer, and writes
# .devin-crew/reviews/<lane>.md (max 15 one-line findings). Returns at once (detached, like crew-launch.sh); the
# conductor, or crew-wait.sh, reports its exit. Reads findings with:  bash crew-review.sh <project> <lane> --findings
set -u
proj=$(cd "$1" && pwd -P) || exit 2
lane=${2:?lane}; mode=${3:-}
here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; rev="$lane-rev"; out="$crew/reviews/$lane.md"
if [ "$mode" = "--findings" ]; then
  [ -s "$out" ] || { echo "(no findings file yet)"; exit 3; }
  head -15 "$out"; high=$(grep -ciE '\((high)\)|: high' "$out"); med=$(grep -ciE '\((med)\)|: med' "$out")
  echo "REVIEW $lane: high=$high med=$med"; [ "$high" -gt 0 ] || [ "$med" -gt 0 ] && exit 1; exit 0
fi
mkdir -p "$crew/reviews" "$crew/prompts" "$crew/lanes"
wd="$proj"; [ -f "$crew/lanes/$lane.workdir" ] && wd=$(cat "$crew/lanes/$lane.workdir")
# acceptance commands and scope of the lane's tasks, from TASKS.md / scopes.txt
rows=$(awk -F'|' -v l="$lane" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 && t($3)==l {print "- task " t($2) ": scope " t($4) "; acceptance: " t($6)}' "$crew/TASKS.md" 2>/dev/null)
globs=$(awk -F'\t' -v l="$lane" '$1==l{printf "%s ", $2}' "$crew/scopes.txt" 2>/dev/null)
cv=$(head -1 "$crew/CONTRACTS.md" 2>/dev/null)
n=1; while [ -e "$crew/prompts/$rev-$n.md" ]; do n=$((n + 1)); done; brief="$crew/prompts/$rev-$n.md"
cat > "$brief" <<BRIEF
Review lane "$lane" (it already exited). Work in this directory ($wd); see its changes with: git diff HEAD   (and git status for new files).
Lane scope: ${globs:-unknown}.  Contracts: $cv  (read $crew/CONTRACTS.md).  The lane's own report is its last DONE line in $crew/BOARD.md: do not trust it, check it.
${rows:-"(no TASKS.md rows for this lane)"}
Do, in this order:
1. Run each acceptance command above once and note the result.
2. Read every changed file. For each test the lane added, ask: would it fail if the code were wrong? Name the concrete mutation that would survive.
3. Probe the edge and error paths of the new code with commands you run from /tmp or with read-only checks (empty, huge, hostile, duplicate input). You may not edit project files.
4. Write your findings to $out in the format from your role (at most 15 lines, or the single line NO FINDINGS). That is the only file you write.
Then post your DONE line.
BRIEF
if [ "$mode" = "--print" ]; then echo "brief: $brief"; cat "$brief"; exit 0; fi
echo "$wd" > "$crew/lanes/$rev.workdir"; : > "$crew/lanes/$rev.readonly"; rm -f "$out"
CREW_ROLE=reviewer bash "$here/crew-launch.sh" "$proj" lane "$rev" - "$brief"
