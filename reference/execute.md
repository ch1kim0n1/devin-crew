# Phase 4 in detail: executing a milestone

(`S` = `~/.claude/skills/devin-crew/scripts`)

## First milestone only: set up

1. Preflight: `bash S/crew-doctor.sh <project> --trust`. It checks login, the model, tools, git state, workspace trust. Any FAIL: tell the user the fix and stop. "Not trusted": the user runs `devin` once in the project and accepts; never bypass trust. The check deletes only its own session.
2. `crew-guard.sh <project> lock`.
3. Write the coordination files (`reference/setup-files.md`): PLAN.md, TASKS.md, ROSTER.md, CONTRACTS.md, scopes.txt, BOARD.md; set the budget with `crew-budget.sh <project> set <minutes>`.
4. `crew-guard.sh <project> baseline "<cmd>"`.
5. Isolation (`reference/guardrails.md`): worktrees (`crew-worktree.sh add <lane>` for every lane) for a git repo root, else `crew-guard.sh <project> snapshot`.

## Per wave

1. Write each task as a brief in `.devin-crew/prompts/<lane>-<n>.md`: goal, owned files, contracts, the exact verify command, definition of done, sibling lanes and what they are doing right now. One milestone per lane turn. `crew-tasks.sh <project> next` lists the tasks that can launch.
2. In `ask` mode show the user what will run: `bash S/devin-lane.sh --print <project> <lane> swe-2-flash-high <task_file>` prints the exact prompt, rights and command without launching.
3. Launch every lane of the wave in one message, each with Bash `run_in_background: true`: `[CREW_ROLE=<implementer|tests|docs|refactor|reviewer>] bash S/devin-lane.sh <project> <lane> swe-2-flash-high <task_file>`, and in the same message `bash S/crew-router.sh <project>` (background too: wakes lanes that get mail, exits once with `QUIESCENT` or `ORCHESTRATOR-MAIL`). Watchdog: 45 min per turn (`CREW_MAX_SECS`). Git rights: `reference/git-rights.md`.
4. Wait for exit notifications (lane exits, router exit). Never poll, never wait blind: the built-in watchdog detects hung commands, empty-reply loops and dead lanes, nudges or kills them, and logs to `.devin-crew/events.log` (`reference/observability.md`).

## On each lane exit

- Not `done`: run `bash S/crew-observe.sh <project> <lane>` before deciding anything. The user asks what a lane is doing: run it too.
- Read the log tail and the lane's DONE line, run `crew-guard.sh <project> check`, route mail (`reference/mail-router.md`), and in worktree mode `crew-worktree.sh <project> merge <lane>`.
- Out-of-scope edits: drop or `restore` them, mail the lane, count a failed attempt.
- Wrong or partial: resume the same lane with a correction file (never a `running` lane).
- `BLOCKED`: answer from CONTRACTS.md, bump `version:`, mail the consumers; escalate to the user only for product decisions.
- Task status is kept by the scripts (`crew-tasks.sh`); mark `done` by hand only for tasks with no acceptance command, after your own check.
