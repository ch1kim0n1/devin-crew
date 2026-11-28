# Autopilot: from approved plan to pull request

(`S` = the `scripts/` folder of this skill; see SKILL.md)

`crew-plan.sh go` and `crew-autopilot.sh` replace the brain-driven loop. The brain is woken once, when the run ends.

## What it does, in order
1. **Load a milestone.** `milestones/m<N>.tasks` rows are appended to `TASKS.md`; every lane that gets work has a fresh worktree that already contains everything merged so far; `.devin-crew/MILESTONE` names it for the QA brief.
2. **Conductor.** `crew-conduct.sh` launches ready tasks in parallel (role picked per task by `crew-roles.sh`), collects, auto-fixes with each lane's own failures, runs reviewer Devins, merges clean lanes (best-of-2 twins keep the better one).
3. **QA.** Specialist reviewers (`security`, `a11y`, `performance`: chosen from the changed files, `CREW_SPECIALISTS` overrides) run in parallel; then the `qa` Devin writes `qa/<n>.md` (PASS / PASS WITH NOTES / FAIL).
4. **QA-FAIL.** Each `FIXTASK: lane | files | acceptance | goal` line becomes a task (`fix<M>r<round>-<k>`, acceptance saved as `acceptance/<id>.sh`, brief in `prompts/`); the lanes run; QA runs again. Cap `CREW_QA_ROUNDS` (3) per milestone; the same failure twice stops the run.
5. **Commit.** After each QA pass, if shipping is authorized, `crew-ship.sh commit` on the branch `crew/<slug>`.
6. **Next milestone**, or after the last: a final QA over the whole objective (only when there was more than one milestone), the reporter Devin (`REPORT.md`), then `crew-ship.sh all`: commit, secrets scan, push, `gh pr create` with the report as body.

With `ship: per-task` steps 5 and 6 change: every task is its own PR (`reference/github.md`), nothing is committed per milestone or shipped at the end.

## Authorization and safety
- Pushing a branch and opening a PR need the user's word at the go (`crew-plan.sh go --ship` writes `ship: yes` in PLAN.md, or `CREW_SHIP_OK=1`). Without it the run ends at `REPORT.md`.
- `crew-ship.sh` never pushes the base branch or main, never forces, refuses without a PASS verdict (`CREW_SHIP_UNVERIFIED=1` is the user's override), blocks on secrets (reports file:line only), leaves out files that were already modified before the crew and no lane owns (`prework.files`), needs `gh auth login`.
- Devin errors (`NEEDS-USER`: limit, login, trust, model, crash) always stop the run; nothing is retried without the user.
- Caps: `CREW_AUTOPILOT_MAX_SECS` (6 h), the lane-minute budget (`BUDGET`), `CREW_QA_ROUNDS`.

## When it stops (ATTENTION)
`.devin-crew/autopilot/ATTENTION` holds the reason and the last conductor digest, and a desktop notification was sent. Reasons: `NEEDS-USER ...` (tell the user, their fix, then retry), `BRAIN <lane>: why`, `ORCHESTRATOR-MAIL`, `PR-WAIT` (per-task PRs or `#n` dependencies: `reference/github.md`), `ENVIRONMENT <services>` (`reference/environment.md`: tell the user), `BUDGET`, `STUCK`, `QA still failing after N rounds`, `QA found the same failures again`, time cap. Handle it (a brief, a scope fix, a plan change after telling the user), `crew-conduct.sh <project> --reset <lane>` for BRAIN lanes, then `crew-autopilot.sh <project> --detach` again: state is in files, it continues.

## Files
`autopilot/` (`pid`, `log`, `loaded`, `current`, `rounds`, `final`, `last.digest`, `ATTENTION`, `DONE`), `milestones/`, `acceptance/`, `qa/` (verdicts, `spec/`), `REPORT.md`, `PR_URL`.
