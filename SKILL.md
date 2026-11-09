---
name: devin-crew
description: Use when the user types /devin-crew, gives a goal for the current project and wants Devin CLI agents to do the work, or asks to run, command, or orchestrate Devin, a Devin crew, or several parallel Devin agents on the project being worked on.
---

# Devin Crew

Three tiers. **The user is the decision maker** (the plan, the scope, the number of workers, every change to them: theirs). **You are the brain and messenger**: you study the project, advise, break the goal down, brief the Devins, route their mail, and check their work. **Devins are workers**: headless Devin CLI agents ("lanes") that take tasks from you and nothing from anyone else. You never override the user; you recommend, they decide.

Scripts live in `~/.claude/skills/devin-crew/scripts/` (`S` below). Devin headless: `devin -p "<prompt>"` runs one turn and exits; `devin -r <id> -p` resumes it; untrusted dirs are refused.

## Invocation

- `/devin-crew` alone: **context only.** Run nothing, create nothing (you may read `S/../AUTONOMY`). Reply in at most 6 lines: you are the brain between them and headless Devin workers; first you study the project and the goal and propose a plan, they decide, then workers run, then you QA each milestone; current autonomy (`ask`/`auto`); ask for the goal. Treat their next goal message as a crew job.
- `/devin-crew <goal>`: start at phase 1.
- `/devin-crew status`: `bash S/crew-status.sh <project>` (live state per lane), and `crew-observe.sh <project>` for anything running or failed; summarize.
- `/devin-crew resume`: `crew-status.sh`; a lane `running-but-NO-PROCESS` is failed; `crew-guard.sh <project> lock --force`; wake or relaunch lanes from saved sessions; continue at phase 4.

## Fixed settings (user's standing rules, 2026-11-09)

Every lane runs `swe-2-flash-high` (script coerces anything else): free, weaker than frontier, so keep scopes tight, contracts explicit, verify everything yourself. Every lane runs in bypass mode (`--permission-mode dangerous`): nothing gates its tools, so scopes, preamble and guards are the only safety. Lanes never commit or push.

## Phases

1. **Recon** (read-only: no devin, no script, no files). Study the project, restate the user's objective, find the scope, find how to verify. Ask the user if the objective is ambiguous. Checklist: `reference/recon-and-plan.md`.
2. **Proposal.** In chat: objective and scope, milestones with tasks, **how many Devins and why** (never more lanes than independent file clusters; cap 5; small or serial work gets 1-2), contracts, isolation mode, QA plan, risks, open questions, your single recommended plan.
3. **Plan with the user.** Revise until they say go. Their edits win; flag risk, then obey. Nothing launches and no `.devin-crew/` exists before the go. `AUTONOMY` file `auto` (set only by the user's own words: "you pick", "stop asking") skips waiting for the go, never phases 1, 2 or 5. Mid-run changes to the plan (more lanes, wider scope, dropped milestone) go back to the user first.
4. **Execute**, per milestone:
   1. First milestone only: trust check (`cd <project> && devin -p "Reply OK, no tools"`; "untrusted workspace" -> ask the user to run `devin` once there; never bypass; delete only the session it created with `devin rm <id> --force`), `crew-guard.sh <project> lock`, write the coordination files (`reference/setup-files.md`), `crew-guard.sh <project> baseline "<cmd>"`, isolation (`reference/guardrails.md`: worktrees for a git repo root, else `snapshot`).
   2. Write each task as a brief in `.devin-crew/prompts/<lane>-<n>.md`: goal, owned files, contracts, exact verify command, definition of done, sibling lanes and what they do now. One milestone per lane turn.
   3. Launch the wave in one message, Bash `run_in_background: true`: `[CREW_ROLE=<implementer|tests|docs|refactor|reviewer>] bash S/devin-lane.sh <project> <lane> swe-2-flash-high <task_file>`, and in the same message `bash S/crew-router.sh <project>` (also background: wakes lanes that get mail, exits once with `QUIESCENT` or `ORCHESTRATOR-MAIL`). Watchdog: 45 min per turn (`CREW_MAX_SECS`).
   4. Wait for exit notifications (lane exits, router exit); never poll and never wait blind: a built-in watchdog detects hung commands, empty-reply loops and dead lanes, nudges or kills them, and logs to `.devin-crew/events.log` (`reference/observability.md`). On every exit that is not `done`, run `bash S/crew-observe.sh <project> <lane>` before deciding. When the user asks what a lane is doing, run it too. On each exit: read log tail and DONE line, `check`, route mail (`reference/mail-router.md`: wake idle lanes with unread mail), worktree mode `merge <lane>`. Wrong or partial: resume the same lane with a correction file. Out-of-scope edits: drop/`restore`, mail the lane, count a failed attempt. BLOCKED: answer from CONTRACTS, bump version, mail consumers; escalate to the user only for product decisions.
5. **QA, after all lanes of the milestone exited.** Devins code fast but miss details and the big idea, so assume the work is incomplete until you prove otherwise. Run `bash S/crew-qa.sh <project>`, `bash S/crew-verify.sh <project>` (acceptance commands + contract freshness) and the full **production checklist** `reference/qa-checklist.md` (mutation spot-check on tests, requirement matrix, edge/error paths, security, docs, end-to-end run, reviewer lane); flow in `reference/qa.md`. Evidence for every item; any open HIGH = FAIL. Verdict PASS / PASS WITH NOTES / FAIL in `.devin-crew/QA.md`. FAIL -> new tasks, back to phase 4. Never tell the user "done" before PASS on every milestone.
6. **Finish.** Last milestone QA'd, `lane-msg.sh pending` empty: `crew-worktree.sh remove` every lane, `crew-guard.sh unlock`. **Report once**: per milestone the QA verdict with commands and results; per lane what it did; reviewer findings and their fate; leftovers and risks; where `.devin-crew/` is. No progress pings before this, unless the user asked to check in at each milestone.

## Stop and ask the user only if

A decision is theirs (product direction, scope, number of workers), an action is destructive or outward-facing (push, deploy, delete, restoring a whole snapshot), trust must be granted, the plan must change, or the same task failed 3 times. Everything else: keep going silently.

## Rules

- You commit only when the user asks; push never without an OK. Worktree merges leave uncommitted edits.
- Lane names are short and stable. Never resume a `running` lane. Never start a second Devin on the same files.
- Summarize, never paste raw Devin logs. Keep `.devin-crew/` after the run; delete only on the user's word.

## Common mistakes

| Mistake | Fix |
|---|---|
| Proposing a plan before reading the project | Phase 1 first, always |
| More lanes than independent file clusters | Fewer lanes; say why |
| Launching before the user's go | Phase 3 gate (unless `auto`) |
| Trusting "DONE" | Rerun acceptance yourself; run the full QA checklist |
| Starting the next milestone without QA | Phase 5 gates every milestone |
| Finishing with unread mail | `lane-msg.sh pending`, wake idle lanes first |
| Judging a `running` lane's files | Check scopes only after lanes exit |
| Waiting on a silent lane | `crew-observe.sh`; devin prints nothing while it works, silence is not progress |
