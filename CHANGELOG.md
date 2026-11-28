# Changelog

## Unreleased

- New: draft pull requests with `pr: draft` in PLAN.md or `CREW_PR_DRAFT=1`.
- Fix: `crew-ship.sh` now requires a real pull request URL from `gh pr create` before it reports `SHIP OK`.
- New: per-task shipping (`crew-plan.sh go --ship-per-task`, or `CREW_SHIP=per-task` with `CREW_SHIP_OK=1`): one branch and PR per task, `issue: <n>` in a brief becomes `Closes #<n>`, dependents and the lane's next task wait for the merge and start from the updated base (#5).
- New: `crew-pr.sh`: `[manager]` / `[lane-x]` comment review loop run by the conductor, `wait` for lanes, `watch` for the manager, `#<n>` issue dependencies in TASKS.md, `PR-WAIT` digest. Only the `gh` account's and repo owners', members' and collaborators' comments count (#6).
- New: `CREW_LANE_UI=tmux|terminal|iterm` runs lanes as visible interactive Devin sessions (#7).
- New: shared services (`.devin-crew/services.txt`, `crew-services.sh`): checked by the doctor and the conductor, restarted with the approved command, no launches or fix rounds while down, `ENVIRONMENT` digest (#8).
- New: `crew-heavy.sh` gate for heavy commands (used for acceptance runs too), `MACHINE-SATURATED` in observe, recheck instead of fix on a saturated machine, lane-count hint from cores and RAM, `sccache` for Rust projects when installed (#9).
- Fix: a worktree merge that included a deleted file did not advance the lane's base, so its next merge reported a false conflict.
- Fix: `crew-doctor.sh` fetches and warns when the branch is behind its upstream or the remote default branch, so lanes do not start from a stale base (#4).
- Fix: `crew-ship.sh` reported success when `git push` or `gh pr create` failed (the exit status was hidden by a pipe).
- Fix: `crew-ship.sh` could not commit under macOS's stock bash 3.2 (syntax error in the secrets scan).
- Tests: smoke suite grows to cover the above.

## 1.4.1 (2026-11-21)

Hotfix found by a real-Devin end-to-end run.
- Fix: a worktree lane whose acceptance needs a sibling's code (the test-first `tests` lane next to `impl`, which the architect plans by default) failed verify forever and burned both fix rounds, then stopped the autopilot with `ATTENTION: BRAIN tests: fix rounds exhausted`. The conductor now parks such a lane (`waiting`) while its siblings are still running or unmerged, copies their merged work into its worktree (`crew-worktree.sh sync <lane>`, a throwaway base commit, the lane's own diff and merge stay lane-only), collects again, and only then spends a fix round.
- Fix: `tests/e2e-real.sh` used `python3 -m unittest`, which finds no tests in `tests/` (exit 5), so its baseline and "project tests pass" checks could never pass; it now uses `unittest discover -s tests`.
- Fix: a lane that owns several tasks no longer marks all of them running/review/done when it runs one (only the task named by the brief, or the lane's single task, moves); a fix brief only revives tasks that already ran.
- Fix: the error classifier no longer reads the agent's own prose ("billing-blocked" in a report was a false RATE_OR_QUOTA); only lines that open like an error count.
- New: `crew-lane-reset.sh <project> <lane>...` recovers a failed or stuck lane in one step (reopens its tasks, clears NEEDS-USER and the sticky lane model, moves the session aside); `crew-conduct.sh --reset` now says it only resets conductor state.
- Tests: smoke suite 210 checks (three new: sibling sync with the reviewer off and on, and the crew-fixes regression suite). Real e2e: 9/9 (23 min).

## 1.4.0 (2026-11-18)

Vague goal in, verified pull request out; a whole team of Devins; the brain only conducts (`reference/autopilot.md`).
- `crew-plan.sh`: read-only architect Devin drafts recon, questions, spec, plan, milestones, tasks, briefs, scopes, contracts; `check`, `apply`, `go`. Untrusted workspace is caught before anything launches.
- `crew-autopilot.sh`: detached run of milestones, QA, fix rounds from `FIXTASK` lines, final QA, report, ship; stops with an `ATTENTION` file and a notification; `--detach/--wait/--status/--stop`.
- `crew-ship.sh`: branch `crew/<slug>`, secrets scan, commit, push, `gh pr create` with the report; refuses without the user's authorization and a QA pass; never main, never force; leaves out the user's pre-existing changes.
- Team: roles `architect backend frontend mobile database devops debugger` and specialist reviewers `security performance a11y`; `crew-roles.sh` picks a role per task from `templates/roles.map` and the specialists from the change; QA fans out specialists then the QA Devin; per-role models (`CREW_MODEL_<ROLE>`, `MODEL.<role>`).
- `crew-race.sh`: best-of-2 twin lanes, the conductor keeps the better one (fewer reviewer findings, then smaller diff).
- `crew-brain-stats.sh`: brain tokens against Devin tokens from the transcripts and ledger, plus Brain-contract violations.
- Fix: `devin-lane.sh` writes `.needs-user` before the failed status becomes visible (the conductor could see `failed` first and misreport). 
- One command: `crew-where.sh` reads the project state and the conductor decides what `/devin-crew` (with any words, or none) means: new goal, progress, continue, stop, change, stats. `status`/`resume`/`stats` stay as optional shortcuts. The go is one question (go with PR / go without PR / change). README rewritten around the single command.
- `tests/e2e-real.sh`: opt-in end-to-end run with the real Devin CLI (needs a folder trusted once). Smoke suite: 205 checks.

## 1.3.0 (2026-11-18)

The brain only conducts: Devins do development, test runs, QA and reporting (`reference/brain-budget.md`, measured on a real 1,252-turn run).
- `crew-audit.sh`: QA Devin (`qa` role, read-only, verdict in `.devin-crew/qa/<n>.md`) and reporter Devin (`reporter` role, `REPORT.md`).
- `crew-conduct.sh`: starts the QA Devin after the last task (`CREW_AUTOQA=1`), `MILESTONE-READY` now means QA passed, new `QA-FAIL` digest with FIXTASK lines, `--report`, `FRESH-SESSION` after `CREW_FRESH_AFTER` (12) wakes.
- `crew-init.sh`: preflight, lock, scope check, baseline and isolation in one call.
- `crew-doctor.sh` flags a stale or partial skill install; `install.sh --codex` replaces a plain copy with a link (old copy moved aside).
- SKILL.md: "Brain contract": the brain never runs project tests/builds, edits project files, reads raw diffs or writes QA/report.
- Tests: 166-check smoke suite.

## 1.2.0 (2026-11-13)

Brain-token optimization with higher Devin utilization (`reference/brain-budget.md`).
- `crew-conduct.sh`: autopilot loop. Launches every ready task in parallel, collects exited lanes, resumes them with their own failures, runs a reviewer Devin, merges clean lanes, and exits once with a digest only when the brain is needed (MILESTONE-READY, BRAIN, NEEDS-USER, ORCHESTRATOR-MAIL, BUDGET, STUCK).
- `crew-collect.sh`: one-call lane digest (acceptance, scope, contract, change size, DONE line, verdict CLEAN/FIX/BRAIN/WAIT, optional merge).
- `crew-review.sh`: read-only reviewer Devin per lane writing at most 15 one-line findings; `reviewer` role rewritten for it.
- `crew-verify.sh` runs a worktree lane's acceptance inside its worktree (`CREW_VERIFY_IN=proj` restores the old behavior). `crew-guard.sh` skips read-only reviewer lanes.
- SKILL.md: conductor-first phase 4, "Brain budget" rules.
- Tests: 153-check smoke suite (new checks for conductor fix/review/merge/brain/needs-user/stuck paths, collect, review); fake `devin` can write files (`STUB_WRITE`).
- Known gaps: conductor not yet run against real Devin end to end (only the fake devin and a read-only collect on a real finished lane); Linux container suite not re-run.

## 1.1.5 (2026-11-11)

- Devin CLI as the manager agent: `reference/devin.md`, `install.sh --devin`; discovery through Devin's Claude importer verified.
- Lane session fallback now ignores sessions older than the lane's start, so a manager session in the same folder is never mistaken for a lane's.
- Lane preamble: lanes must not invoke the devin-crew skill or start other sessions.
- Known gaps: no full crew run yet with Devin or Codex as the manager; Linux container suite last run before the Codex and Devin changes.

## 1.1.0 (2026-11-11)

- Codex as the manager agent: `reference/codex.md` (tool substitutions, sandbox settings, loop), `agents/openai.yaml`, `AGENTS.md`, `install.sh --codex`.
- `crew-launch.sh`, `crew-wait.sh`, `crew-notify.sh` for agents without a background-run tool or push tool.
- `crew-doctor.sh` fails with the fix when a sandbox disables the network or makes Devin's data folder read-only.
- Skill paths are no longer Claude-specific in the docs.
- Known gaps: not run end to end under Codex; the Linux container suite was last run (117/117, Debian 12) before these changes and is pending a re-run.

## 1.0.0 (2026-11-11)

First public release.

- Three tiers: you decide, Claude plans/briefs/checks, headless Devin lanes work.
- Recon and proposal in one reply, led by the Devin count; nothing launches before your go.
- Isolation by git worktree or shared tree with snapshot; scope guard and overlap lint.
- Versioned contracts, lane mail, router, task graph (`TASKS.md`), `PLAN.md` + `crew-resume.sh`.
- Watchdog: hung-command kill, empty-reply nudges, per-turn cap, lane-minute budget.
- Devin errors (limit, login, trust, model, crash, unexplained exit) stop the lane, go to you, and retry only on your word (`CREW_RETRY_OK=1`); timed retry at the reset time; push notification.
- Production QA gate per milestone: acceptance rerun, mutation check, requirement matrix, reviewer lane, QA history.
- Opt-in git rights for lanes (`CREW_GIT`).
- Cross-project usage ledger and `/devin-crew stats [viz]`.
- Configurable lane model (`MODEL` file or `CREW_MODEL`).
- Tested: 118-check offline smoke test on macOS, the same suite on Debian 12 in a container, real 3-lane and 5-lane Devin runs on macOS.
