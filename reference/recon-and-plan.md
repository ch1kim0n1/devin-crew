# Recon and proposal (phases 1-3)

(`S` = `~/.claude/skills/devin-crew/scripts`)

Recon is **read-only**: no `devin` call, no script, no file created, nothing written into the project. Use Read/Grep/Glob and read-only git/shell (`git status`, `git log`, `ls`, running nothing that changes state).

## 1. Recon checklist

1. **Project shape.** Top-level layout; languages; frameworks; entry points; size. Is the project dir a git repo root (-> worktree mode), a plain folder, or a parent of several repos (-> shared tree, or pick one repo as the project)?
2. **Conventions and docs.** README, CLAUDE.md/AGENTS.md, CONTRIBUTING, lint/format config.
3. **How to verify.** Test, build, lint commands that exist and look runnable. This becomes the baseline command and every acceptance command. None exist: say so; the plan needs a task that adds one.
4. **State.** `git status` (uncommitted work the lanes would start from), current branch, recent commits touching the objective's area.
5. **Objective.** Restate the user's goal in 1-3 lines with what "done" looks like. Too ambiguous to size even roughly: ask the user now (AskUserQuestion) and include your provisional lane count in the question. Otherwise do not ask: go straight to the proposal in the same reply, Devin count first.
6. **Scope.** Which files/dirs the objective actually touches, which it must not touch, and the size of the change (files, rough lines). Anything shared across the touch-points (a type, an API, a config) is a contract candidate.

## 2. Proposal (shown in chat; the user decides)

Present, in this order and compactly:

- **Objective and scope** as you understood them, plus what is explicitly out of scope.
- **Milestones**: M1..Mn, each a deliverable that can be checked on its own. Each lists its tasks: lane, role, owned files, depends-on, acceptance command.
- **How many Devins, and why.** Rule of thumb: one lane per cluster of files that can be changed independently; never more lanes than disjoint clusters; cap 5; a small or strictly serial job gets 1-2 lanes, and say so even if it is less impressive. State the cost of more lanes (coordination, merge conflicts) next to the gain.
- **Contracts** the lanes share (each with owner lane and consumers).
- **Isolation**: worktrees or shared tree, and why. Warn if the main tree has uncommitted work (the lanes start from it).
- **Fixed settings** reminder: `swe-2-flash-high`, bypass mode, git rights (default none; lanes commit or push only if the user says so).
- **QA plan**: what you check after each milestone (see `reference/qa.md`), whether a reviewer lane runs, the baseline command.
- **Risks and open questions** for the user: weak spots in the plan, unknowns from recon, decisions only they can make.
- **Recommendation**: the one plan you would run. Alternatives only if the choice really is theirs.

## 3. Plan with the user

The user decides; you advise. Revise the proposal on their feedback until they say go (any clear yes). Their edits win: fewer lanes, different scope, skipped QA step, changed milestones. Say plainly if an edit raises risk (e.g. two lanes on one file), then do what they decide. Nothing is launched, and no `.devin-crew/` is created, before the go. Mid-run, anything that changes this plan (more lanes, wider scope, dropped milestone) goes back to the user first.

`AUTONOMY=auto` (set only by the user's own words) skips the wait for a go but not the recon, the proposal, or QA: show the plan in chat, then proceed.
