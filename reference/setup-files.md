# Coordination files (`.devin-crew/` in the project)

## TASKS.md
Markdown table, one row per task; the last cell is the status (`open`, `running`, `done`, `failed`). `crew-status.sh` counts these; `crew-verify.sh` runs the acceptance cell (a shell command from the project root; no `|` inside; `-` skips).

```
| id | lane | scope | depends | acceptance | status |
|----|------|-------|---------|------------|--------|
| t1 | api  | src/api/* | -  | python3 -m unittest tests.test_api | open |
| t2 | tests| tests/*   | t1 | python3 -m unittest | open |
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

Also created automatically: `inbox/`, `lanes/` (status, pid, sid, model, workdir), `logs/`, `prompts/`, `wt/`, `snapshot.*`, `baseline.*`, `LOCK`. Add `.devin-crew/` to the project's ignore file (`crew-worktree.sh add` does it for `.git/info/exclude`).
