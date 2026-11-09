# Observability: knowing what a lane is really doing

(`S` = `~/.claude/skills/devin-crew/scripts`)

A headless `devin -p` prints almost nothing while it works, so "no output" tells you nothing and a hung lane looks identical to a busy one. Never wait blind. The skill gives you three layers:

1. **Watchdog (automatic).** `devin-lane.sh` checks the lane every 30s (after the first 90s) with `crew-observe.sh --stall`. A hung command is killed (Devin sees a failed tool call and goes on); a stalled model is killed and the session is resumed with a nudge, up to `CREW_STALL_RETRIES` (2) times; a still-stalled lane ends as `failed(stalled: <STATE>)`; a turn past `CREW_MAX_SECS` (2700, fresh for each nudge) ends the lane as `failed(timeout)`. Every step is written to `.devin-crew/events.log`.
2. **Diagnosis (on demand).** `bash S/crew-observe.sh <project> [lane]` is the full picture; use it whenever a lane exits not-`done`, whenever the user asks "what is it doing", and whenever something looks off. `crew-status.sh` shows each running lane's live state in one line. `crew-observe.sh <project> --timeline` prints the events log.
3. **Raw sources** if the diagnosis is not enough (read only the lane's own data):
   - Devin's session store `~/.local/share/devin/cli/sessions.db` (sqlite, open with `sqlite3 -readonly`). `sessions.id` = session, `working_directory` = the lane's workdir; `message_nodes` = every message (`chat_message` JSON: role, content, tool_calls; `created_at` epoch); `tool_call_state` = every tool call (`tool_call_json` title/kind/rawInput, `tool_call_update_json` status; NULL update = still in flight). Query by the lane's own session id only.
   - Devin's process log `~/.local/share/devin/cli/logs/devin_*_<pid>.log`, named by the pid of the `devin acp` child of the lane's `devin -p` process.
   - The lane's own stdout/stderr: `.devin-crew/logs/<lane>.<n>.log`.
   - Never read `credentials.toml`, other sessions' contents, or anything outside the lane's own session.

## What the states mean and what to do

| State | Meaning | Action |
|---|---|---|
| `ACTIVE` / `THINKING` | Real progress recently, or normal model latency | Leave it |
| `WORKING-TOOL` | A command is running and CPU or session activity shows life | Leave it; check elapsed time in the report |
| `STALLED-TOOL-HUNG` | A command ran with ~0% CPU and no activity past `CREW_TOOL_STALL_SECS` (1200) | Watchdog kills the command. Repeats: the command is wrong (waits on stdin, a server in the foreground); resume with a task that avoids it |
| `STALLED-EMPTY-RESPONSE` | The model answered with nothing, repeatedly; Devin keeps re-prompting itself with "continue" and never exits (seen in practice: a lane idled 11 min this way) | Watchdog kills + nudges. Check the files the lane already wrote (the work is often done); if nudges fail, finish the remainder via a narrower fresh task |
| `STALLED-AWAITING-MODEL` | Last record is a prompt or tool result and no reply for `CREW_MODEL_STALL_SECS` (420) | Same as above; also check network/quota (error class) |
| `STALLED-TOOL-NO-PROCESS` | A tool call was issued but no command is running | Same |
| `STALLED-NOT-EXITING` | Final answer given, process stays alive | Kill is safe; treat the lane as done after checking its work |
| `STALLED-UNKNOWN` | Nothing at all for 2x the model-stall limit | Kill, resume once, then report |
| `CRASHED` | Status says running, process gone | Failed. Read the process log tail, resume or relaunch |
| `FAILED` / `TIMEOUT` | Exited nonzero / hit the wall clock | Use the error class below |
| `FINISHED` | Exited 0 | Normal path: verify and QA |

"Progress" means a tool result or an assistant message with text or tool calls. Empty replies and Devin's own "continue" prompts are not progress.

## Error classes (printed with evidence lines and a remedy)

`AUTH` (ask the user to `devin auth login`), `RATE_OR_QUOTA` (wait, or the user's call), `TRUST`, `PERMISSION` (lane was not in bypass mode), `CONTEXT_TOO_LONG` (fresh lane, narrower task), `NETWORK`, `MODEL`, `CRASH`, `TIMEOUT` (split the task). Anything unclassified: read the log tail the report prints.

## Discipline

- On every lane exit that is not `done`, run `crew-observe.sh` **before** deciding anything; say in the QA/report what the diagnosis was.
- A lane that was nudged or tool-killed gets extra scrutiny in QA: it may have skipped the part where it stalled.
- Retries are bounded. After the automatic nudges, a lane that is still stuck counts as a failed attempt toward the "same task failed 3 times -> ask the user" rule.
- Repeated `RATE_OR_QUOTA`, `AUTH` or `NETWORK` across lanes is an environment problem, not a lane problem: stop launching, tell the user.
