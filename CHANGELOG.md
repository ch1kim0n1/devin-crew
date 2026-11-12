# Changelog

## 1.1.0 (unreleased)

- Codex as the manager agent: `reference/codex.md` (tool substitutions, sandbox settings, loop), `agents/openai.yaml`, `AGENTS.md`, `install.sh --codex`.
- `crew-launch.sh`, `crew-wait.sh`, `crew-notify.sh` for agents without a background-run tool or push tool.
- `crew-doctor.sh` fails with the fix when a sandbox disables the network or makes Devin's data folder read-only.
- Skill paths are no longer Claude-specific in the docs.

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
