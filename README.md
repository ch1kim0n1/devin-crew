# devin-crew

**Make Claude Code the manager of a crew of headless [Devin CLI](https://devin.ai) agents.**
You set the goal and approve the plan. Claude studies your project, proposes how many Devins to use and why, briefs them, watches them, merges their work and QAs it before it tells you anything is done.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ch1kim0n1/devin-crew)](https://github.com/ch1kim0n1/devin-crew/releases)
![Platforms](https://img.shields.io/badge/macOS%20%E2%9C%93%20%7C%20Linux%20(offline%20tests)-lightgrey)

[Install](#install) · [Let Claude install and adapt it](#let-claude-install-and-adapt-it) · [How it works](#how-it-works) · [Commands](#commands) · [Safety](#safety-read-this-first) · [Configuration](#configuration) · [FAQ](#faq)

```
   YOU            decide: the plan, the scope, how many workers, every change to them
    |
  CLAUDE          the brain and messenger: studies the project, proposes a breakdown,
    |             briefs the workers, routes their mail, watches them, QAs their work
 DEVIN, DEVIN…    workers: take tasks from Claude, nothing else
```

## Why

One agent works through a big job one thing at a time. Several agents on one folder step on each other, and headless Devin runs print almost nothing while they work, so a hung lane looks busy. Devin's default model is cheap but weaker, so its "done" needs checking.

devin-crew gives you the parallelism without those problems:

- **You stay in charge.** Nothing launches before you say go. Claude recommends, you decide: lanes, scope, budget, git rights.
- **Lanes don't collide.** Each Devin gets its own git worktree (or a shared tree with a snapshot), owned files, versioned contracts for shared interfaces, and a mailbox to talk to the others.
- **Hangs get caught.** A watchdog reads Devin's own session store and process tree, kills hung commands, nudges stuck lanes, and enforces time and lane-minute budgets.
- **Devin errors reach you.** A usage limit, login or trust problem stops that lane, Claude tells you with the evidence and your fix, and nothing retries until you say so. If the message gives a reset time, Claude can retry at that time with your permission.
- **Work is checked, not trusted.** Every milestone goes through acceptance reruns, a mutation spot-check of the tests, a requirement matrix, edge and error paths, security, docs, an end-to-end run and an independent reviewer lane.
- **It survives a context reset.** The approved plan lives in `.devin-crew/PLAN.md`; `/devin-crew resume` rebuilds the picture from files.

## How it works

1. **Recon** (read-only) and **proposal in one reply**, opening with the Devin count: `3 Devins: api (src/api/*), ui (web/*), tests (tests/*) because …`, plus milestones, contracts, QA plan, git rights and a budget.
2. **You revise and say go.** Your edits win.
3. **Execute** per milestone: briefs, lanes launched in the background together with a mail router, watchdog on every lane.
4. **QA** after all lanes of a milestone exit. Any open HIGH is a FAIL and goes back to the lanes.
5. **One final report**, plus a push notification, so you can walk away.

Example (illustrative, abridged):

```
you:    /devin-crew add rate limiting to the API, with tests and docs
claude: [reads the repo; creates nothing]
        PROPOSAL: 3 Devins
          api   src/api/ratelimit/*, src/api/middleware.ts   the limiter and its wiring
          tests tests/ratelimit/*                            tests against the contract, not the code
          docs  docs/api.md                                  usage and limits
        Contract v1: RateLimiter.check(key) -> {allowed, retryAfter}   owner: api, consumer: tests, docs
        Isolation: worktrees. Budget: 45 lane-minutes. Git: none. QA: acceptance + mutation check + reviewer lane.
        Earlier crews of yours: median 40 lane-minutes, one stall.
        Go?
you:    go, but no docs lane, I'll write them
claude: Plan updated to 2 Devins. Writing .devin-crew/PLAN.md and launching…
```

## Install

Requirements: [Claude Code](https://claude.com/claude-code), the [Devin CLI](https://devin.ai) installed and logged in (`devin auth login`), and `bash`, `git`, `python3`, `sqlite3`, `tar`, `pgrep`/`pkill`.

```bash
curl -fsSL https://raw.githubusercontent.com/ch1kim0n1/devin-crew/main/install.sh | bash
```

It clones to `~/.claude/skills/devin-crew` (or pass another folder) and re-running it updates (fast-forward only). By hand:

```bash
git clone https://github.com/ch1kim0n1/devin-crew ~/.claude/skills/devin-crew
```

Then restart Claude Code and check your setup in the project you want to use it on:

```bash
bash ~/.claude/skills/devin-crew/scripts/crew-doctor.sh <your-project> --trust
```

`--trust` runs one tiny Devin turn to confirm the folder is trusted (run `devin` once in the folder and accept if it is not). Uninstall: `rm -rf ~/.claude/skills/devin-crew`; each project's `.devin-crew/` folder is separate.

## Let Claude install and adapt it

Paste one of these into Claude Code. Claude does the work and tells you what it changed.

**Install and verify**

```text
Install the devin-crew Claude Code skill from https://github.com/ch1kim0n1/devin-crew
(run its install.sh), then run scripts/crew-doctor.sh against this project and fix or
explain every FAIL. Read its README.md and SKILL.md and summarize in five lines how I use it.
```

**Adapt it to your setup**

```text
I installed devin-crew in ~/.claude/skills/devin-crew. Read README.md, SKILL.md and
reference/. Adapt it for me: <what you want, for example:
  - use model <id> for all lanes (see `devin models`) via the MODEL file
  - never more than 3 lanes (edit the cap in SKILL.md and reference/recon-and-plan.md)
  - lanes may commit to my feature branch but never push (git rights, reference/git-rights.md)
  - always ask me before every launch (set AUTONOMY to ask)
  - budget default of 60 lane-minutes>.
Make the smallest change that does it, run `bash tests/smoke.sh` and `shellcheck -S warning scripts/*.sh`
afterwards, and show me the diff before you finish.
```

**Port it to another headless agent CLI** (a real piece of work: the watchdog reads Devin's session store)

```text
Read devin-crew's scripts/devin-lane.sh and scripts/crew-observe.sh. Plan, without changing anything yet,
what it takes to run lanes with <codex exec | gemini -p | other> instead of devin: the command line,
how to get a session id and resume, what replaces the sessions.db checks, and what the tests need.
```

**Try it safely first**

```text
Clone this repo to a temp folder, run /devin-crew on the clone with a small goal, use 2 lanes at most,
and show me the proposal before launching anything.
```

## Commands

| You type | What happens |
|---|---|
| `/devin-crew` | Heads-up only: what it does, current autonomy, asks for your goal. Runs nothing. |
| `/devin-crew <goal>` | Recon and proposal in one reply, then plan with you, execution and QA |
| `/devin-crew status` | Live state of every lane |
| `/devin-crew resume` | Rebuild a half-done crew from `.devin-crew/` and continue |
| `/devin-crew stats` | How you have used Devin across projects: time, tasks, tokens, QA, fun facts. Add `viz` for an HTML report with charts |

Dry run any launch with `bash scripts/devin-lane.sh --print <project> <lane> - <task_file>`: it prints the exact prompt, rights and command and starts nothing.

## Safety (read this first)

Lanes run Devin in **bypass mode** (`--permission-mode dangerous`): nothing asks permission before a lane runs a command or edits a file. Guardrails (file scopes, worktrees, snapshots, scope checks, no git writes by default) limit the damage; they are **not a sandbox**.

- Try it on a throwaway clone first. Keep your work committed.
- Don't run it where secrets or production systems are reachable. For real isolation use a container or VM.
- Nothing is pushed unless you say so, and never forced.
- The skill itself sends nothing anywhere (Devin talks to its own servers as usual). Run state is in `.devin-crew/`, kept out of your commits via `.git/info/exclude`. The usage ledger is a local file in the skill folder.

Details: [SECURITY.md](SECURITY.md).

## Configuration

| Setting | How | Default |
|---|---|---|
| Lane model | `MODEL` file next to `SKILL.md`, or `CREW_MODEL` | `swe-2-flash-high` |
| Ask before launching | `AUTONOMY` file: `ask` or `auto` (`auto` only on your say-so) | `ask` |
| Lane git rights | Tell Claude, or `CREW_GIT=commit\|push`, `CREW_GIT_TARGET="origin main"` | none |
| Lane-minutes budget | `scripts/crew-budget.sh <project> set <minutes>` | set in the plan |
| Per-turn time cap | `CREW_MAX_SECS` | 2700 |
| Stall nudges | `CREW_STALL_RETRIES` | 2 |
| Role of a lane | `CREW_ROLE=implementer\|tests\|docs\|refactor\|reviewer` | none (plain worker) |
| Approve a retry after a Devin error | `CREW_RETRY_OK=1` (Claude sets it only after you say retry) | off |
| Ledger location / off | `CREW_LEDGER=<file>` / `off` | `usage/ledger.tsv` |

## FAQ

**Does it work outside a git repo?** Yes: a shared tree with a pre-launch snapshot instead of worktrees. Less protection.

**Which model do the Devins use?** One model for all lanes, `swe-2-flash-high` unless you change it. It is cheap or free and weaker than frontier models, which is why scopes are tight and QA is strict. Check `devin models`.

**A lane stopped with a limit, login or trust error. Now what?** Claude tells you right away with the evidence and the fix (for example `devin auth login`). Fix it and say "retry", or just say "retry". If the error names a reset time, Claude offers a timed retry.

**Can I stop it?** Close the session or tell Claude to stop; `scripts/crew-status.sh <project>` shows lanes, and `scripts/crew-guard.sh <project> unlock` frees the project lock. Worktree changes are only merged into your tree as uncommitted edits.

**Does it use GitHub CI?** No. Verification is local; Claude trusts what it ran itself.

**What does it cost?** Devin usage per your plan; the default model is free at the time of writing. Lane-minutes are capped by the budget you approve. Token numbers in `/devin-crew stats` are estimates.

**Windows?** Untested; try WSL.

**How is this different from running several agents in tmux or an app like Conductor?** Those give you panes. This adds a plan you approve, contracts and mail between lanes, a watchdog, error handoff to you, and a QA gate per milestone. If you want a GUI, use one of those.

## Project layout

```
SKILL.md                the skill: flow and rules Claude follows
reference/              the detail behind each phase (recon, execute, git rights, guardrails, QA checklist…)
scripts/                devin-lane.sh (run a lane), crew-* helpers (worktrees, guard, observe, verify, router,
                        resume, tasks, budget, doctor, status, report, analytics, retry-at, ledger), lane-msg.sh
templates/              lane preamble and role presets
tests/                  smoke.sh (offline, fake devin), linux-docker.sh, pressure-scenarios.md,
                        trigger-prompts.md, fixtures/, e2e-log.md
install.sh              install / update
```

## Status and testing

- 118 offline checks with a fake `devin` (`bash tests/smoke.sh`), shellcheck-clean; the same suite passes on Debian 12 in a container (`bash tests/linux-docker.sh`).
- Real Devin runs on macOS: a 3-lane trial and a 5-lane contract-first run with hung-command recovery, a mid-run contract change, a read-only reviewer and a mutation check ([tests/e2e-log.md](tests/e2e-log.md)).
- Claude's own discipline (the gate, the QA, error handoff) is checked with fresh-model paper scenarios (`tests/pressure-scenarios.md`) and a trigger check on the skill description (`tests/trigger-prompts.md`).
- **Not yet exercised:** real Devin runs on Linux, large codebases (thousands of files), shared-tree mode with 5 lanes. Expect rough edges; please [open an issue](https://github.com/ch1kim0n1/devin-crew/issues).

## Contributing, security, changelog

[CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE). devin-crew is an independent project and is not affiliated with or endorsed by Cognition (Devin) or Anthropic (Claude Code); product names belong to their owners.
