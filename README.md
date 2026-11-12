# devin-crew

A [Claude Code](https://claude.com/claude-code) skill that turns Claude into the **control panel for a crew of headless [Devin CLI](https://devin.ai) agents** working on one project.

```
   YOU            decide: the plan, the scope, how many workers, every change to them
    |
  CLAUDE          the brain and messenger: studies the project, proposes a breakdown,
    |             briefs the workers, routes their mail, watches them, QAs their work
 DEVIN, DEVIN…    workers: take tasks from Claude, nothing else
```

You give a goal. Claude reads the project, proposes milestones and **how many Devins to deploy and why**, and waits for your go. Only then do workers start. Claude watches them (and recovers from hangs), merges their work, and runs a production QA checklist on every milestone before it tells you anything is done.

## What it does

- **Recon, proposal, plan with you.** Read-only study of the project first; nothing launches before you say go (unless you explicitly set autonomy to `auto`).
- **Lanes that know about each other.** Every Devin is told it is one of several working at once. They share a roster (who owns which files), versioned contracts (shared interfaces) and per-lane mail. Claude wakes idle lanes when mail arrives.
- **Isolation.** Git repo: one detached worktree per lane, merged back as uncommitted edits, in-scope files only. Otherwise a shared tree with a pre-launch snapshot and a scope check.
- **Observability.** `devin -p` prints almost nothing while it works, so a hung lane looks like a busy one. A watchdog reads Devin's own session store, process tree and logs; kills hung commands; nudges lanes stuck in empty-reply loops; classifies errors (auth, quota, network, trust, context…); keeps an event log.
- **Production QA.** Devins are fast and miss details and big ideas. A mechanical net (`crew-qa.sh`) plus a manual checklist (requirement matrix, mutation spot-check of tests, edge and error paths, security, docs, end-to-end run, independent reviewer lane) gates every milestone.

## Requirements

- Claude Code
- [Devin CLI](https://devin.ai) installed and logged in (`devin auth login`), the project folder trusted once (`devin` in it)
- `bash`, `git`, `python3`, `sqlite3`, `tar`, and `pgrep`/`pkill` (procps)
- macOS: tested with real Devin runs. Linux: the offline suite passes on Debian 12 (`tests/linux-docker.sh`); no real Devin runs yet. Windows: untested (try WSL).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ch1kim0n1/devin-crew/main/install.sh | bash
```

Or by hand: `git clone https://github.com/ch1kim0n1/devin-crew ~/.claude/skills/devin-crew`. Restart Claude Code (or start a new session), then check your setup:

```bash
bash ~/.claude/skills/devin-crew/scripts/crew-doctor.sh <your-project> --trust
```

Update: re-run the installer (fast-forward only). Uninstall: `rm -rf ~/.claude/skills/devin-crew` (your projects' `.devin-crew/` folders are separate; delete them if you no longer need the logs).

## Read this before the first run

Lanes run Devin in **bypass mode**: nothing asks permission before a lane runs a command or edits a file. Guardrails (file scopes, worktrees, snapshots, scope checks) limit the damage; they are not a sandbox. Try it on a throwaway clone first, keep your work committed, and read [SECURITY.md](SECURITY.md). The skill sends nothing anywhere itself; the usage ledger stays on your machine.

## Use

| You type | What happens |
|---|---|
| `/devin-crew` | Heads-up only. Claude acknowledges the mode and asks for your goal. Runs nothing. |
| `/devin-crew <goal>` | Recon, proposal, plan with you, then execution and QA |
| `/devin-crew status` | Live state of each lane |
| `devin-lane.sh --print ...` | Dry run: the exact prompt a lane would get, nothing launched |
| `/devin-crew resume` | Pick up a half-done crew from `.devin-crew/` |

To let Claude skip the wait for your go: tell it to decide on its own (it writes `AUTONOMY=auto`). It still does recon, shows the plan, and does QA.

## Defaults

- Every lane runs one model, `swe-2-flash-high` by default (free). Put another model id in a file named `MODEL` next to `SKILL.md`, or set `CREW_MODEL`, to change it for all lanes. Check ids with `devin models`.
- Every lane runs in Devin's **bypass mode** (`--permission-mode dangerous`): all tool approvals off. The only guardrails are file scopes, the lane preamble, the snapshot/worktree and the checks. Read `SKILL.md` before running this on anything you cannot afford to lose.
- Verification is local: Claude trusts what it ran itself (acceptance commands, project tests, QA checklist) and never waits on GitHub CI.
- Lanes never commit or push by default. If you tell Claude to ("have them commit", "commit and push to origin main"), it launches them with `CREW_GIT=commit` or `CREW_GIT=push CREW_GIT_TARGET="origin main"`: each lane stages only its own scoped files, commits after its verify passes, and pushes with a plain `git push` (never forced; one rebase retry, then BLOCKED). Lanes commit per verified unit of work, not one giant commit and not per tiny edit. Shared-tree mode only; with worktrees Claude commits after merge instead. A standing "commit and push regularly" instruction counts as the go-ahead.

## Layout

```
SKILL.md                    the skill (flow, rules)
reference/                  recon & plan, execute, setup files, git rights, mail & router, guardrails, observability, QA + checklist
scripts/devin-lane.sh       run/resume one lane with watchdog and auto-nudge
scripts/crew-worktree.sh    worktree add / merge / remove
scripts/crew-guard.sh       lock, baseline/regress, snapshot, scope check, restore
scripts/crew-observe.sh     what is a lane really doing; why did it fail
scripts/crew-qa.sh          mechanical QA over the diff
scripts/crew-qa-history.sh  what QA found before; watch list for later milestones
scripts/crew-verify.sh      run TASKS.md acceptance commands, check contract freshness
scripts/crew-router.sh      wake lanes that get mail; exits when the crew is quiet
scripts/crew-resume.sh      rebuild a run from files (plan, state, next steps) after a reset
scripts/crew-tasks.sh       keep TASKS.md statuses true (set, lane, next)
scripts/crew-report.sh      per-lane nudges, kills, elapsed time
scripts/crew-ledger.sh      appends lane turns and QA findings to the cross-project usage ledger (local, git-ignored)
scripts/crew-retry-at.sh    retries a lane that hit a Devin error at a time the user approved (sleeps, then relaunches)
scripts/crew-analytics.sh   usage, time, tasks, projects, tokens, QA and fun facts across projects; `viz` writes an HTML report
scripts/crew-budget.sh      lane-minutes cap; launches refused when exceeded
scripts/crew-doctor.sh      preflight: login, model, tools, git state, workspace trust
scripts/crew-status.sh      one-screen status
scripts/lane-msg.sh         mail between lanes
templates/                  lane preamble and role presets
tests/smoke.sh              offline regression test (fake devin, shellcheck), `bash tests/smoke.sh`
tests/linux-docker.sh       the same suite on Linux in a container
install.sh                  install / update
CHANGELOG.md  SECURITY.md  CONTRIBUTING.md
```

## Status

Tested offline (`bash tests/smoke.sh`, 118 checks with a fake `devin`) and in real runs with real Devin lanes: a 3-lane trial and a 5-lane run with a mid-run contract change, hung-command recovery, a read-only reviewer and a mutation check (`tests/e2e-log.md`). Claude's own gate and QA discipline is checked with fresh-model pressure scenarios (`tests/pressure-scenarios.md`) and the description with a trigger check (`tests/trigger-prompts.md`). The offline suite also passes on Debian 12 in a container. Not yet exercised: real Devin runs on Linux, large codebases (thousands of files), shared-tree mode with 5 lanes. Expect rough edges and open an issue.

## License

MIT
