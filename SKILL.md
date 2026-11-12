---
name: devin-crew
description: Use when the user types /devin-crew, gives a goal for the current project and wants Devin CLI agents to do the work, or asks to run, command, or orchestrate Devin, a Devin crew, or several parallel Devin agents on the project being worked on.
---

# Devin Crew

Three tiers. **The user is the decision maker** (the plan, the scope, the number of workers, every change to them: theirs). **You are the brain and messenger**: you study the project, advise, break the goal down, brief the Devins, route their mail, and check their work. **Devins are workers**: headless Devin CLI agents ("lanes") that take tasks from you and nothing from anyone else. You never override the user; you recommend, they decide.

Scripts live in the `scripts/` folder next to this file (`S` below): `~/.claude/skills/devin-crew/scripts` under Claude Code, `~/.codex/skills/devin-crew/scripts` under Codex. Detail lives in `reference/`; read the file a step points to when you reach that step. **Running under Codex or Devin, or any agent without Claude Code's tools (no background-run tool, `PushNotification`, `AskUserQuestion`)? Read `reference/codex.md` (Codex) or `reference/devin.md` (Devin as the manager) first** and use its substitutions; everything else applies unchanged. In Codex the skill is invoked as `$devin-crew`; in Devin and Claude Code as `/devin-crew`.

## Invocation

- `/devin-crew` alone: **context only.** Run nothing, create nothing (you may read `S/../AUTONOMY`). Reply in at most 6 lines: you are the brain between them and headless Devin workers; first you study the project and goal and propose a plan, they decide, then workers run, then you QA each milestone; current autonomy (`ask`/`auto`); ask for the goal. Treat their next goal message as a crew job.
- `/devin-crew <goal>`: the user has already decided to use a crew, so do phase 1 and then phase 2 in the same reply. Never stop after recon to ask "how many Devins?" or "what do you want?". The proposal opens with the Devin count (N lanes, one line each: name, job, owned files) and why that many. Ask a question only if the goal is too ambiguous to size; even then give a provisional count.
- `/devin-crew status`: `bash S/crew-status.sh <project>`, plus `crew-observe.sh <project>` for anything running or failed; summarize.
- `/devin-crew stats`: only when the user asks how they use Devin (usage, time, tasks, projects, tokens, QA, fun facts) across all projects: `bash S/crew-analytics.sh`, summarize. Add `viz` (`bash S/crew-analytics.sh viz`) when they ask for charts or a report, then show the HTML with `SendUserFile` (display render). Never build or send it unasked. Data: `S/../usage/ledger.tsv`, written by the lane and QA scripts, local and git-ignored.
- `/devin-crew resume`: `bash S/crew-resume.sh <project>` prints the approved plan, live state and a numbered NEXT list. Follow it; confirm with the user first if PLAN.md is missing. Continue at phase 4.

## Defaults

Every lane runs one model: `swe-2-flash-high` by default (free, weaker than frontier, so keep scopes tight, contracts explicit, verify everything yourself). The user can change it for all lanes with a `MODEL` file next to this skill or `CREW_MODEL`; the script coerces any other model. Change it only on their word. Every lane runs in bypass mode (`--permission-mode dangerous`): nothing gates its tools, so scopes, preamble and guards are the only safety. Lanes do not touch git unless the user said so (`reference/git-rights.md`).

## Phases

1. **Recon** (read-only: no devin, no script, no files). Study the project, restate the user's objective, find the scope, find how to verify. Ask if the objective is ambiguous. Checklist: `reference/recon-and-plan.md`.
2. **Proposal**, in chat, led by **how many Devins and why** (never more lanes than independent file clusters; cap 5; small or serial work gets 1-2), then: objective and scope; milestones with tasks; contracts; isolation mode; QA plan; git rights (default none); a lane-minutes budget (run `bash S/crew-analytics.sh hint` first: if it prints anything, base the lane count and budget on those earlier crews and say so in one line) (parallel lanes add up; a small task is tens of minutes, a big one a few hours); risks; open questions; your single recommended plan.
3. **Plan with the user.** Revise until they say go. Their edits win; flag risk, then obey. Nothing launches and no `.devin-crew/` exists before the go. The `AUTONOMY` file set to `auto` (only by the user's own words: "you pick", "stop asking") skips waiting for the go, never phases 1, 2 or 5. Plan changes mid-run (more lanes, wider scope, dropped milestone) go back to the user first. On the go, write the approved plan to `.devin-crew/PLAN.md` (format in `reference/setup-files.md`) and keep it current: it is all that survives a context reset.
4. **Execute**, per milestone (full steps: `reference/execute.md`). First milestone: `crew-doctor.sh <project> --trust`, lock, coordination files, budget, baseline, isolation. Each wave: write briefs (goal, owned files, contracts, exact verify command, definition of done, what siblings are doing now), show `devin-lane.sh --print` to the user in `ask` mode, launch every lane plus `crew-router.sh` in one message with `run_in_background: true`. Wait for exit notifications; never poll or wait blind. On every exit not `done`, `crew-observe.sh` first. Then read the DONE line, `crew-guard.sh check`, route mail, merge (worktrees). Wrong or partial: resume the same lane with a correction.
5. **QA, after all lanes of the milestone exited.** Devins code fast but miss details and the big idea: assume the work is incomplete until you prove otherwise. Run `crew-qa.sh`, `crew-verify.sh`, and the full production checklist `reference/qa-checklist.md` (mutation spot-check, requirement matrix, edge/error paths, security, docs, end-to-end run, reviewer lane, QA history watch list); flow in `reference/qa.md`. Evidence for every item; any open HIGH is a FAIL. Verdict PASS / PASS WITH NOTES / FAIL in `.devin-crew/QA.md`. FAIL: new tasks, back to phase 4. Never tell the user "done" before PASS on every milestone.
6. **Finish.** Last milestone QA'd, `lane-msg.sh pending` empty: `crew-worktree.sh remove` every lane, `crew-guard.sh unlock`. **Report once** (and send a `PushNotification`, one line: the verdict and what needs them, since they may have walked away): per milestone the QA verdict with commands and results; per lane what it did; reviewer findings and their fate; leftovers and risks; where `.devin-crew/` is. No progress pings before this, unless the user asked to check in at each milestone.

## Stop and ask the user only if

A decision is theirs (product direction, scope, number of workers), an action is destructive or outward-facing (push, deploy, delete, restoring a whole snapshot), trust must be granted, the plan must change, the budget is exceeded (launches are refused until they say raise it), the same task failed 3 times, or **Devin itself errors out** (usage limit, login, trust, model, crash, or an exit with no cause). The lane script writes `lanes/<lane>.needs-user` and prints `NEEDS-USER`; tell the user at once, even while other lanes run: which lane, the class, the evidence, their fix. Also send a `PushNotification` (load it with ToolSearch `select:PushNotification`; one line under 200 chars, lead with the action: `devin-crew: lane api stopped, Devin usage limit, resets 14:30. Fix or say retry.`) so they see it away from the screen. They fix it and say retry, or just say retry; only then relaunch with `CREW_RETRY_OK=1` (the script refuses otherwise, exit 5). When the evidence has a reset time (`crew-observe.sh <project> <lane> --reset` prints the epoch), offer "retry at HH:MM?" and on their yes run `bash S/crew-retry-at.sh <project> <lane> auto` in the background. Never retry such an error silently. Everything else: keep going silently.

## Rules

- Git: default nobody commits or pushes. The user's chat instruction, or a standing instruction in their memory/CLAUDE.md to commit and push regularly, is the authorization; mechanics and cadence in `reference/git-rights.md`. Never force-push.
- Verification is local. A passing local run (acceptance commands, `crew-verify.sh`, the project's tests, the QA checklist) is what counts. Do not wait on, poll or report GitHub CI unless asked; never claim a pass you did not run.
- Lane names are short and stable. Never resume a `running` lane. Never start a second Devin on the same files.
- Summarize, never paste raw Devin logs. Keep `.devin-crew/` after the run; delete only on the user's word.

## Common mistakes

| Mistake | Fix |
|---|---|
| Proposing a plan before reading the project | Phase 1 first, always |
| Stopping after recon to ask what to do | Same reply: recon, then the proposal with the Devin count |
| Retrying a Devin limit/login error on your own | Report to the user; `CREW_RETRY_OK=1` only after their word |
| More lanes than independent file clusters | Fewer lanes; say why |
| Launching before the user's go | Phase 3 gate (unless `auto`) |
| Trusting "DONE" | Rerun acceptance yourself; run the full QA checklist |
| Starting the next milestone without QA | Phase 5 gates every milestone |
| Finishing with unread mail | `lane-msg.sh pending`, wake idle lanes first |
| Judging a `running` lane's files | Check scopes only after lanes exit |
| Waiting on a silent lane | `crew-observe.sh`; devin prints nothing while it works, silence is not progress |
