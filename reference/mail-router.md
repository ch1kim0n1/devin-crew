# Mail and the router

(`S` = `~/.claude/skills/devin-crew/scripts`)

Lanes talk with `bash S/lane-msg.sh <project> send|read|pending ...` (the preamble teaches them). They check mail at start, after each milestone, and before DONE, so a running lane sees mail within minutes. A lane that already finished never sees mail on its own: **you are the wake-up.**

**Router process (preferred).** After launching a wave, also start `bash S/crew-router.sh <project>` with Bash `run_in_background: true`. It polls every 15 s, wakes idle lanes with unread mail, and exits with one line when the crew is quiet: `QUIESCENT` (go to QA), `ORCHESTRATOR-MAIL <n>` (read it, answer, start the router again), `QUIESCENT-WITH-STUCK-MAIL lane(status,n)...` (those lanes are stalled/timed out/never started: decide yourself), or `ROUTER-TIMEOUT` (`CREW_ROUTER_MAX_SECS`, 7200). Only lanes with status `done` or `failed(<number>)` are woken. Its exit is the signal to start QA; lanes still run their own watchdogs.

Manual router (what the process automates): run `bash S/lane-msg.sh <project> pending` after every lane exit and before declaring anything finished. It prints `<lane> <status> <unread>`.

- status `done` / `failed(n)` with unread mail: wake it with `bash S/devin-lane.sh <project> <lane> - -` (reuses its model and session, delivers the mail), in the background.
- status `running`: leave it; it reads the mail at its next checkpoint. Re-check when it exits.
- mail for `orchestrator`: read it with `bash S/lane-msg.sh <project> read orchestrator`. Answer from CONTRACTS.md yourself; bump `version:` and mail the consumers if a contract changed. Escalate to the user only for a product decision you cannot derive.
- Two lanes mailing back and forth ~3 rounds without converging: settle it yourself in CONTRACTS.md.

Contract changes go through the owner lane or you: edit CONTRACTS.md, bump `version:`, mail every consumer. Lanes re-read it at checkpoints.
