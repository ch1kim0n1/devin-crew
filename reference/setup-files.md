# Coordination files (`.devin-crew/` in the project)

## TASKS.md
Markdown table, one row per task; the last cell is the status (`open`, `running`, `review`, `done`, `failed`), maintained by the scripts: `devin-lane.sh` sets a lane's open/failed/review tasks to `running` at launch and to `review` (exited ok, unverified) or `failed` at exit; `crew-verify.sh` sets `done` on a passing acceptance and `failed` otherwise; `crew-tasks.sh <project> set <id> <status>` is for manual calls (tasks with no acceptance command: you mark `done` after your own check) and `crew-tasks.sh <project> next` lists open tasks that can launch now (deps done, lane idle). `crew-status.sh` counts these; `crew-verify.sh` runs the acceptance cell (a shell command from the project root; no `|` inside; `-` skips).

```
| id | lane | scope | depends | acceptance | status |
|----|------|-------|---------|------------|--------|
| t1 | api  | src/api/* | -  | python3 -m unittest tests.test_api | open |
| t2 | tests| tests/*   | t1 | python3 -m unittest | open |
```

## PLAN.md
Written by you the moment the user says go (phase 3), updated when they change the plan. It is what `/devin-crew resume` and `crew-resume.sh` rebuild from after a context reset, so it must stand alone:

```
approved: 2026-11-10
goal: <the user's objective in one sentence>
scope: <what is in, what is out>
isolation: worktree | shared
lanes: <n>: <lane (role, owns ...)>, ... and why this many
autonomy: ask | auto
git: none | commit | push <remote> <branch>
budget_minutes: <lane-minutes cap> | none
milestones:
- M1: <deliverable> (tasks t1-t3)
- M2: ...
current: M1
```

## ROSTER.md
Per lane: job, role, owned files, port/temp path, and for each contract it owns the **consumer lanes** to notify.

```
- api (implementer): owns src/api/*; port 4101; owns contract `slugify`; consumers: tests, docs
- tests (tests): owns tests/*; no port
```

## CONTRACTS.md
First line `version: 1`. Every shared interface (signatures, API shapes, file formats), each with an owner lane and a change log line per change. Written before anyone codes against it.

## scopes.txt
`<lane><TAB><glob relative to project>`, one line per owned path. Mirrors ROSTER.md; `crew-guard.sh check` and `crew-worktree.sh merge` read it. Globs use shell `case` matching, so `src/api/*` covers everything below it.

## BOARD.md
Starts empty. Public log of all lane mail plus the `DONE` lines (`DONE <lane>: files changed: ... | verified: ... | contracts: v<N> | open issues: ...`; `crew-verify.sh` compares `v<N>` with the version line of CONTRACTS.md). Lanes append only.

`BUDGET`: lane-minutes cap (one number), written by `crew-budget.sh set`. `devin-lane.sh` refuses to launch and `crew-router.sh` refuses to wake lanes once the sum of all lane run times (events.log `elapsed=` plus lanes running now) reaches it.

Also created automatically: `inbox/`, `lanes/` (status, pid, sid, model, workdir), `logs/`, `prompts/`, `wt/`, `snapshot.*`, `baseline.*`, `LOCK`. Add `.devin-crew/` to the project's ignore file (`crew-worktree.sh add` does it for `.git/info/exclude`).
