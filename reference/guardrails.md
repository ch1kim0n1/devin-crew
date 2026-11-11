# Guardrails

(`S` = `~/.claude/skills/devin-crew/scripts`)

All via `bash S/crew-guard.sh <project> <cmd>` unless noted.

| Command | Use |
|---|---|
| `lock [--force]` / `unlock` | One crew per project; a lock older than 2h is stale |
| `baseline "<cmd>"` / `regress` | Run the project's tests/build before launch; `regress` reruns and shows exit change and new output lines (a lane may have caused them) |
| `snapshot` | tar of the project minus node_modules/.git/dist/build/.next/target/venv (override with `CREW_PRUNE`); refuses over 2GB |
| `check` | Scope violations; exit 1 if any |
| `restore <path>` | Put one file back as snapshotted, or delete it if it did not exist |

## Isolation: worktrees vs shared tree

- **Worktrees** (project is a git repo root): `bash S/crew-worktree.sh <project> add <lane>` for every lane before launching. Detached worktree at `.devin-crew/wt/<lane>`; no branches, no commits on the user's branches. Uncommitted work already in the main tree (earlier waves) is copied in, so later waves build on earlier ones. Top-level `node_modules`, `.venv`, `venv` are symlinked so tests can run. Each lane sees only its own files: cross-lane verification happens in the main tree after merging.
- `check` in worktree mode compares each worktree with **its own lane's** scope, so violations are attributed exactly.
- `merge <lane>` applies the lane's in-scope changes to the main tree as **uncommitted** edits (bytecode and OS noise ignored) and lists files it left behind. If the whole patch does not apply (an earlier merge touched the same file), every file that does apply is applied and the conflicting ones are listed with the path of the lane's version: reconcile those by hand keeping both lanes' work, or resume the lane with the merged file. The usual cause is two lanes owning the same file: `crew-guard.sh <project> scopes` lints scopes.txt for same or nested paths (`crew-worktree.sh add` warns), and `crew-guard.sh check` reports `OVERLAP` per changed file in worktree mode too. Fix overlaps in the plan (one owner per file, or sequence the lanes), not at merge time.
- **Next wave or correction in worktree mode:** a lane's worktree is frozen at the base it was created from. Before resuming a lane after other lanes merged, `crew-worktree.sh remove <lane>` then `add <lane>` (same path, so its Devin session continues; it now starts from the merged tree and can run the real integrated tests). Merge its work first; removal discards what was not merged.
- **Shared tree** (not a git repo, or a parent folder of several repos): all lanes edit the same files. `check` compares with the snapshot and flags files no scope covers or two scopes cover; it cannot say which lane did it. Never judge a file while its lane is still `running`.
- Mixed modes in one run are unsupported.

## Watchdog

`devin-lane.sh` watches every lane: wall-clock cap `CREW_MAX_SECS` (2700) -> `failed(timeout)`; hung commands killed; empty-reply or other stalls killed and resumed with a nudge (`CREW_STALL_RETRIES`, 2). Details, states and thresholds: `reference/observability.md`.

## Restoring

Single out-of-scope files: restore freely and tell the lane. Whole snapshot, or files inside a lane's own scope: only with the user's OK.
