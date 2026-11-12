# Running devin-crew with Devin CLI as the manager

Devin plays the role Claude plays in SKILL.md: it studies the project, proposes, briefs, watches and QAs. The lanes stay separate `devin -p` worker processes. Everything in SKILL.md applies. `S` = the `scripts/` folder of this skill. The launch, wait and loop mechanics are the ones in `reference/codex.md` sections 2 and 3 (same helpers); this file lists what is specific to Devin.

**Status.** Checked on this setup (devin 3000.12.43): Devin lists `devin-crew` among its skills when it is installed under `~/.claude/skills`. Written from Devin's docs for the rest. Not yet run: a full crew with Devin as the manager. Trust `crew-doctor.sh` and your tool list over this file where they disagree, and open an issue.

## Install and invoke

- Already have it for Claude Code (`~/.claude/skills/devin-crew`)? Devin loads skills through its Claude importer, so nothing to do.
- Otherwise `bash install.sh --devin` (clones into `~/.config/devin/skills/devin-crew`), or put it in a project at `.devin/skills/devin-crew/`.
- Invoke with `/devin-crew <goal>` (the folder name is the skill's name). Devin reads `AGENTS.md` automatically.

## Substitutions

| SKILL.md says | In Devin |
|---|---|
| Bash `run_in_background: true`, wait for exit notifications | Devin backgrounds a long shell command itself but is **not notified** when it ends. Use `bash S/crew-launch.sh <project> lane <lane> - <task_file>` (returns at once) and `bash S/crew-wait.sh <project> 90`. Keep the wait short so it returns before Devin's default wait period moves it to the background; call it again after handling each result |
| `PushNotification` | `bash S/crew-notify.sh "<one line>"` and the same line first in your reply |
| `AskUserQuestion` | `ask_user_question`, or plain text |
| Claude subagents | Do not use Devin subagents (`run_subagent`) as lanes. They cannot nest, have no mail, contracts, watchdog or per-lane budget. Lanes are `devin -p` processes started by the scripts |
| stats report file | print the path of `usage/report.html` |

## Settings that matter

- **Manager permissions.** Run the manager in Normal or Smart mode and approve or allow-list the crew scripts (see Devin's permissions docs, https://docs.devin.ai/cli/reference/permissions, for the rule syntax). Bypass for the manager is your call; lanes run in bypass regardless, so read SECURITY.md. Bypass never overrides organization-level permissions.
- **Manager model.** Start the manager on a strong model (`devin --model <id>`; see `devin models`). Lanes use the fixed lane model (`MODEL` file, default `swe-2-flash-high`); do not copy the manager's model onto them.
- **Do not `/handoff` to the cloud mid-crew.** Cloud Devin cannot see the local worktrees.

## Manager and lanes share one folder and one session store

- Lane sessions are identified from each lane's `--export` file. If that is missing, the fallback only considers sessions created after the lane started, so the manager's own session is never taken for a lane's.
- The preamble tells every lane it is a worker: it must not invoke devin-crew or start other sessions.
- `devin list` shows the manager and the lanes together. Delete only sessions you created; `crew-doctor.sh --trust` removes only its own.
- A rate or usage limit hits the manager and the lanes alike. When a lane stops with `NEEDS-USER`, tell the user as SKILL.md says; the manager may be limited too.
