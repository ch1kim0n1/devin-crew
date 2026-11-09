# Milestone QA (phase 5)

(`S` = `~/.claude/skills/devin-crew/scripts`)

Run after **every lane of a milestone has exited** (not while any is `running`), and again over the whole objective after the last milestone. QA is yours. A lane's DONE line is a claim, not evidence.

**The full production checklist is `reference/qa-checklist.md`; it is mandatory for every milestone.** Devins are fast but skip details and big ideas, so nothing is "done" until that checklist has evidence for every item. Start with `bash S/crew-qa.sh <project>` (mechanical net). The list below is the short form of the flow, not a substitute.

## Checklist (write results to `.devin-crew/QA.md`, one section per milestone)

1. **Lanes finished clean**: `crew-status.sh` shows no `failed`, no `running-but-NO-PROCESS`; unread mail is empty (`lane-msg.sh pending`).
2. **Acceptance**: `bash S/crew-verify.sh <project>` reruns every TASKS.md acceptance command for finished lanes in the main tree (worktree mode: after `merge`) and checks that each lane's DONE line says `contracts: v<current>`. `FAIL`, `TIMEOUT` and `STALE-CONTRACT` lines are failures (a stale lane coded against an old contract: resume it with the new one). Record command and exit code. `bash S/crew-report.sh <project>` shows nudges, hung-tool kills and elapsed time per lane: scrutinize lanes that needed rescue.
3. **Scope**: `crew-guard.sh check` clean; nothing left behind by `merge`.
4. **No regressions**: `crew-guard.sh regress` against the baseline. New failing output is a FAIL unless it is expected by the milestone.
5. **Read the diff.** `git diff` / `git status` of the main tree: does the change do what the objective and the milestone say, nothing extra, no debug leftovers, no secrets, no stray files? Spot-check against CONTRACTS.md.
6. **Independent review**: launch a reviewer lane (`CREW_ROLE=reviewer`, no scope lines in scopes.txt, run in the merged main tree after a fresh `snapshot`). A reviewer that changes any file is a scope violation. Triage each finding: real -> task; false -> note why in QA.md.
7. **Objective check**: would the user, reading the milestone's result, agree it delivers the milestone? State the one place you are least sure.

## Verdict

`PASS`: all of 2-4 green, no open real findings. Mark the milestone done, start the next one (or finish).
`FAIL`: list the failures as new tasks in TASKS.md, assign them (resume the lane that owns the file, or a fresh lane), rerun QA for the milestone. Each FAIL counts toward the "same task failed 3 times" stop.
`PASS WITH NOTES`: green, but unresolved doubts the user should see; copy them into the final report.

## Reporting

Normally nothing goes to the user between milestones (one report at the end). The final report includes the QA verdict per milestone with the commands and results. If the user asked to check in at each milestone, stop after a PASS and give a short QA summary; continue on their word.
