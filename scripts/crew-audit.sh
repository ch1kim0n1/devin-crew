#!/usr/bin/env bash
# Hand verification and reporting to Devins so the brain never runs tests or reads diffs itself.
#   bash crew-audit.sh <project> qa [--print]     launch a QA Devin (lane qa-<round>, read-only on the project) over the finished milestone;
#                                                 it runs crew-qa/verify/guard and the production checklist and writes .devin-crew/qa/<round>.md
#   bash crew-audit.sh <project> specialists      launch the specialist reviewers the change needs (crew-roles.sh specialists: security, a11y, performance), read-only,
#                                                 each writes .devin-crew/qa/spec/<round>-<name>.md; prints the lanes launched. The next `qa` folds them in.
#   bash crew-audit.sh <project> report [--print] launch a reporter Devin (lane report) that writes .devin-crew/REPORT.md
#   bash crew-audit.sh <project> path             path of the newest QA verdict file (exit 3 if none)
#   bash crew-audit.sh <project> verdict          newest QA verdict, short. Exit 0 PASS / PASS WITH NOTES, 1 FAIL, 3 none yet
# Returns at once (detached, like crew-launch.sh). The conductor (crew-conduct.sh) calls this by itself when a milestone's tasks are all done.
# Optional .devin-crew/MILESTONE (one line) names the milestone in the QA brief.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
kind=${2:-}; mode=${3:-}
here="$(cd "$(dirname "$0")" && pwd)"; ref="$here/../reference"; crew="$proj/.devin-crew"
mkdir -p "$crew/qa" "$crew/prompts" "$crew/lanes"
newest() { local f best=0 n; for f in "$crew"/qa/[0-9]*.md; do [ -e "$f" ] || continue; n=$(basename "$f" .md); [ "$n" -gt "$best" ] 2>/dev/null && best=$n; done; [ "$best" -gt 0 ] && echo "$crew/qa/$best.md"; }
case "$kind" in
  path) f=$(newest); [ -n "$f" ] && echo "$f" || exit 3; exit 0;;
  verdict)
    f=$(newest); [ -n "$f" ] && [ -s "$f" ] || { echo "(no QA verdict yet)"; exit 3; }
    head -16 "$f"; v=$(head -1 "$f" | tr '[:lower:]' '[:upper:]')
    case "$v" in FAIL*) exit 1;; PASS*) exit 0;; *) echo "QA verdict file does not start with PASS/PASS WITH NOTES/FAIL"; exit 3;; esac;;
  specialists)
    n=1; while [ -e "$crew/prompts/qa-$n.md" ]; do n=$((n + 1)); done
    ms=$(head -1 "$crew/MILESTONE" 2>/dev/null)
    : > "$crew/qa/specialist-lanes"; mkdir -p "$crew/qa/spec"
    for sp in $(bash "$here/crew-roles.sh" specialists "$proj"); do
      [ -f "$here/../templates/roles/$sp.md" ] || continue
      lane="spec-$sp-$n"; out="$crew/qa/spec/$n-$sp.md"; brief="$crew/prompts/$lane.md"
      cat > "$brief" <<BRIEF
Review the finished milestone${ms:+ "$ms"} of this project ($proj) as the $sp specialist. All lanes have exited and their work is in this tree: see it with git status and git diff HEAD, and read the changed and new files. Read $crew/PLAN.md for the objective and $crew/CONTRACTS.md for the interfaces. Write your findings to $out in your role's format (the only file you write), then post your DONE line.
BRIEF
      echo "$proj" > "$crew/lanes/$lane.workdir"; : > "$crew/lanes/$lane.readonly"; rm -f "$out"
      CREW_ROLE=$sp bash "$here/crew-launch.sh" "$proj" lane "$lane" - "$brief" >/dev/null 2>&1 && { echo "$lane" >> "$crew/qa/specialist-lanes"; echo "$lane"; }
    done;;
  qa)
    n=1; while [ -e "$crew/prompts/qa-$n.md" ]; do n=$((n + 1)); done
    specs=$(ls "$crew"/qa/spec/"$n"-*.md 2>/dev/null | tr '\n' ' ')
    lane="qa-$n"; out="$crew/qa/$n.md"; brief="$crew/prompts/$lane.md"
    ms=$(head -1 "$crew/MILESTONE" 2>/dev/null)
    lanes=$(awk -F'|' 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 {id=t($2); if(id=="id"||id==""||id ~ /^-/||id ~ /^:/) next; printf "- %s (lane %s): acceptance: %s\n", id, t($3), t($6)}' "$crew/TASKS.md" 2>/dev/null)
    prev=$(newest)
    cat > "$brief" <<BRIEF
QA the milestone${ms:+ "$ms"} of this project ($proj). All its lanes have exited and their work is merged into this tree. Read $crew/PLAN.md first (objective, milestones, contracts) and $crew/CONTRACTS.md.
Tasks and their acceptance commands:
${lanes:-"(no TASKS.md rows)"}
${specs:+Specialist reviewers already looked (security, a11y, performance); read their findings: $specs Every HIGH they report must either appear in your verdict or be disproved with evidence in one line.
}${prev:+Previous QA round: $prev (its findings were handed back to the lanes; confirm each is fixed, do not just trust that).}
Do, in this order, with evidence for each:
1. bash $here/crew-verify.sh $proj  (reruns every acceptance command; FAIL, TIMEOUT and STALE-CONTRACT lines are failures)
2. bash $here/crew-qa.sh $proj  (mechanical net over the whole change) and bash $here/crew-guard.sh $proj check, then bash $here/crew-guard.sh $proj regress (new failures against the baseline).
3. The project's own full test, lint and build commands, once (find them in the repo; note exit codes).
4. The production checklist $ref/qa-checklist.md, every item: requirement matrix against the objective, mutation spot-check (in a throwaway copy only), edge and error paths, security, docs, one end-to-end run of the real thing, and the QA history watch list. Read the diff yourself where those items need it.
5. Write the verdict to $out in the format of your role (first line PASS | PASS WITH NOTES | FAIL), and append the same section, headed with the date and verdict, to $crew/QA.md.
Then post your DONE line.
BRIEF
    [ "$mode" = "--print" ] && { echo "brief: $brief"; cat "$brief"; exit 0; }
    echo "$proj" > "$crew/lanes/$lane.workdir"; : > "$crew/lanes/$lane.readonly"; rm -f "$out"
    echo "$lane" > "$crew/qa/lane"
    CREW_ROLE=qa bash "$here/crew-launch.sh" "$proj" lane "$lane" - "$brief";;
  report)
    out="$crew/REPORT.md"; brief="$crew/prompts/report.md"
    cat > "$brief" <<BRIEF
Write the final report of this crew run to $out (the only file you write). Sources: $crew/PLAN.md, TASKS.md, QA.md and qa/*.md (QA verdicts), reviews/*.md (reviewer findings), BOARD.md (each lane's DONE lines), events.log, and bash $here/crew-report.sh $proj (effort per lane), bash $here/lane-msg.sh $proj pending (unread mail), git status of $proj. Say what was built against the user's objective in PLAN.md, the QA verdict per milestone with commands and results, per lane what it did, reviewer findings and their fate, leftovers and risks. At most 45 lines. Then post your DONE line.
BRIEF
    [ "$mode" = "--print" ] && { echo "brief: $brief"; cat "$brief"; exit 0; }
    echo "$proj" > "$crew/lanes/report.workdir"; : > "$crew/lanes/report.readonly"; rm -f "$out"
    CREW_ROLE=reporter bash "$here/crew-launch.sh" "$proj" lane report - "$brief";;
  *) sed -n 2,9p "$0"; exit 2;;
esac
