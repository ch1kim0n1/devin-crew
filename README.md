# devin-crew

**One command. Claude Code (or Codex) conducts a whole team of headless [Devin CLI](https://devin.ai) agents: you give a goal, they plan, build, test, review and open the pull request.**

```
/devin-crew add dark mode to the settings page
```

That is the whole interface. It asks at most three questions, shows you a one-page plan, and waits for one answer: *go, open a PR when done* / *go, no PR* / *change the plan*. Then you can walk away; you hear back when it is finished or when it truly needs you. Type `/devin-crew` again any time (even with no words) and it tells you where things stand and carries on.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ch1kim0n1/devin-crew)](https://github.com/ch1kim0n1/devin-crew/releases)
![Agents](https://img.shields.io/badge/manager-Claude%20Code%20%7C%20Codex%20%7C%20Devin-informational)
![Platforms](https://img.shields.io/badge/macOS%20%E2%9C%93%20%7C%20Linux%20(offline%20tests)-lightgrey)

[Install](#install) · [Let Claude install and adapt it](#let-claude-install-and-adapt-it) · [How it works](#how-it-works) · [Using it](#using-it) · [Safety](#safety-read-this-first) · [Configuration](#configuration) · [FAQ](#faq)

```
   YOU            one command: /devin-crew <what you want>. Say go. That is all.
    |
  CONDUCTOR       Claude / Codex: decides, asks you at most three questions, deploys Devins,
    |             wakes only when something needs you (it never builds, tests or reviews itself)
 A TEAM OF        architect, backend, frontend, mobile, database, devops, tests, docs, QA,
 DEVINS           security / performance / a11y reviewers, reporter: they plan, build, test,
                  review, report, and open the pull request
```

Works with **Claude Code** (primary, tested with real runs), **Codex** (`$devin-crew`; see [Codex](#codex)) and **Devin CLI itself** (`/devin-crew`; see [Devin as the manager](#devin-as-the-manager)) as the manager agent. The workers are always Devin CLI agents.

## Why

One agent works through a big job one thing at a time. Several agents on one folder step on each other, and headless Devin runs print almost nothing while they work, so a hung lane looks busy. Devin's default model is cheap but weaker, so its "done" needs checking.

devin-crew gives you the parallelism without those problems:

- **You stay in charge.** No worker touches your project before you say go (only the read-only architect looks). The conductor recommends, you decide: the plan, scope, and whether a PR is opened.
- **Lanes don't collide.** Each Devin gets its own git worktree (or a shared tree with a snapshot), owned files, versioned contracts for shared interfaces, and a mailbox to talk to the others.
- **Hangs get caught.** A watchdog reads Devin's own session store and process tree, kills hung commands, nudges stuck lanes, and enforces time and lane-minute budgets.
- **Devin errors reach you.** A usage limit, login or trust problem stops that lane, Claude tells you with the evidence and your fix, and nothing retries until you say so. If the message gives a reset time, Claude can retry at that time with your permission.
- **Vague goal in, pull request out.** Give a goal; an architect Devin drafts the plan, the conductor asks at most three questions, you say go (and whether it may open a PR), and an autopilot runs milestones, QA with specialist reviewers, fix rounds, a final QA and the report, then pushes a `crew/<slug>` branch and opens the PR. Never main, never forced, secrets scanned.
- **A whole team of Devins.** Roles for backend, frontend, mobile, database, devops, debugging, tests, docs, refactoring, architecture, review, QA, reporting and security/performance/a11y specialists; the role is picked from the files a task touches. Risky tasks can race two Devins and keep the better result.
- **Work is checked, not trusted, and not by the expensive model.** Every milestone goes through acceptance reruns, a mutation spot-check of the tests, a requirement matrix, edge and error paths, security, docs, an end-to-end run and an independent reviewer lane. A QA Devin runs all of it and a reporter Devin writes the final report; the Claude/Codex brain only decides, talks to you and deploys Devins.
- **It survives a context reset.** The approved plan lives in `.devin-crew/PLAN.md`; typing `/devin-crew` again rebuilds the picture from files and carries on.

## How it works

1. **You type one command with a goal.** The conductor checks where the project stands, then has a read-only architect Devin study the project and draft the plan (recon, testable acceptance criteria, milestones, tasks, briefs, who owns which files).
2. **At most three questions, one go.** The conductor shows a one-page plan opening with the Devin count and why. You answer: *go, open a PR when done* / *go, no PR* / *change the plan*. Your edits win.
3. **The autopilot runs it.** Per milestone: Devins build in isolated worktrees, a reviewer checks each lane, specialists (security, a11y, performance) and a QA Devin verify the milestone, failures become fix tasks, then a final QA over the whole goal.
4. **One report, one PR.** A reporter Devin writes the report; the conductor pushes a `crew/<name>` branch and opens the pull request (only if you said so). You are notified once, or earlier if a Devin error needs you.

Example (illustrative, abridged):

```
you:    /devin-crew add rate limiting to the API, with tests and docs
claude: Studying the project... (a Devin drafts the plan; nothing is changed yet)
        PLAN: 3 Devins - api (limiter + wiring), tests (against the contract), docs.
        Done means: 1) limiter returns allowed/retryAfter  2) 429 on the API  3) tests + docs.
        One question: per API key or per IP? (default: per API key)
you:    per key
claude: Go, open a PR when done / Go, no PR / Change the plan?
you:    go, open a PR
claude: Running. I will tell you when it is finished or if it needs you.
  ...later...
claude: Done. QA passed, 2 notes. PR: https://github.com/you/api/pull/42
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

### Codex

```bash
curl -fsSL https://raw.githubusercontent.com/ch1kim0n1/devin-crew/main/install.sh | bash -s -- --codex
```

This puts the skill in `~/.codex/skills/devin-crew` (or links an existing Claude install). In Codex type `$devin-crew <goal>` or pick it with `/skills`. Codex's default sandbox blocks the network, which Devin needs: run `bash ~/.codex/skills/devin-crew/scripts/crew-doctor.sh <project> --trust` and follow [reference/codex.md](reference/codex.md) for the `config.toml` settings. Codex has no background-run tool, so the skill uses `crew-launch.sh` / `crew-wait.sh` / `crew-notify.sh` there. **Status: the scripts and packaging are tested offline; I have not yet run a full crew under Codex.**

### Devin as the manager

Devin CLI loads skills from `~/.claude/skills` through its Claude importer, so an existing Claude install is already visible to it (checked on devin 3000.12.43: `devin-crew` appears in Devin's skill list). Otherwise:

```bash
curl -fsSL https://raw.githubusercontent.com/ch1kim0n1/devin-crew/main/install.sh | bash -s -- --devin
```

which clones into `~/.config/devin/skills/devin-crew`. Type `/devin-crew <goal>` in Devin. Devin is not notified when a background command ends, so the skill uses `crew-launch.sh` / `crew-wait.sh` there. Start the manager on a strong model (`devin --model <id>`); lanes keep their own fixed model. Read [reference/devin.md](reference/devin.md). Lanes are told they are workers and must not invoke the skill themselves. **Status: skill discovery verified; I have not yet run a full crew with Devin as the manager.**

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

## Using it

There is one command, and you never have to remember options. Type `/devin-crew` (in Codex, `$devin-crew`) and say what you want in your own words:

| You say | What happens |
|---|---|
| `/devin-crew <a goal, however vague>` | A read-only architect Devin studies the project and drafts the plan. You answer up to three questions, then say go. The crew builds, tests, reviews, and (if you said so) opens a pull request. |
| `/devin-crew` (nothing) | If a crew exists it reports where things stand and continues; if not, it asks what the crew should work on. |
| `/devin-crew how is it going` / `continue` / `stop` / `also do X` / `how much have I used Devin` | Understood in plain words; no special syntax. |

Shortcuts like `status`, `resume`, `stats` still work, but nothing requires them. Under the hood the conductor reads the project's state (`scripts/crew-where.sh`) and decides what your words mean.

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

**Can Devin be the manager too?** Yes in design, see above: same scripts, `/devin-crew`, launch/wait helpers, and a guard so the manager session is never mistaken for a lane. Not yet run end to end. Using Devin subagents as lanes is not supported.

**Does it work with Codex?** As the manager, yes in design: same scripts, `$devin-crew`, launch/wait helpers instead of background tools, and a doctor that checks the sandbox. Not yet run end to end under Codex; reports welcome. Codex as a *worker* (instead of Devin) is not supported.

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

- 137 offline checks with a fake `devin` (`bash tests/smoke.sh`), shellcheck-clean; the same suite passes on Debian 12 in a container (`bash tests/linux-docker.sh`).
- Real Devin runs on macOS: a 3-lane trial and a 5-lane contract-first run with hung-command recovery, a mid-run contract change, a read-only reviewer and a mutation check ([tests/e2e-log.md](tests/e2e-log.md)).
- Claude's own discipline (the gate, the QA, error handoff) is checked with fresh-model paper scenarios (`tests/pressure-scenarios.md`) and a trigger check on the skill description (`tests/trigger-prompts.md`).
- **Not yet exercised:** real Devin runs on Linux, large codebases (thousands of files), shared-tree mode with 5 lanes. Expect rough edges; please [open an issue](https://github.com/ch1kim0n1/devin-crew/issues).

## Contributing, security, changelog

[CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CHANGELOG.md](CHANGELOG.md)

## License

[MIT](LICENSE). devin-crew is an independent project and is not affiliated with or endorsed by Cognition (Devin) or Anthropic (Claude Code); product names belong to their owners.
