# Shared services and a busy machine

(`S` = the `scripts/` folder of this skill; see SKILL.md)

Two failures hit every lane at once and look like bad code: a shared service dies, or the machine runs out of CPU.

## Shared services
Optional `.devin-crew/services.txt` (the architect drafts `draft/services.txt` when tests need running services), one per line, tab separated:

`<name><TAB><health command><TAB><restart command, optional>`

for example `db`, `pg_isready -h localhost -p 5432`, `docker start crew-pg`. Commands run from the project root, unattended, so the user approves them with the plan: `crew-plan.sh check` prints them, and you show them in the proposal (the one place the user sees commands). Neither a hurry nor `AUTONOMY=auto` approves a service command, and a changed `services.txt` needs their word again. A restart command must be safe to repeat and never delete or reset data.

- Preflight: `crew-doctor.sh` fails while a service is down. It only checks, never restarts: the user starts the service before the run.
- During a run the conductor checks every `CREW_SERVICE_POLL` (60 s) and again before blaming a lane for a failure. While anything is down it launches, collects and fixes nothing, runs the restart command (`CREW_SERVICE_RESTARTS`=3 per outage), and the router wakes nobody. Running lanes are not stopped: they see `ENVIRONMENT DOWN` when they read mail, and their instructions say to rerun later or end with `BLOCKED: environment <service>`, not to change code.
- After recovery the conductor collects as usual; a lane that stopped on `BLOCKED: environment` is resumed by a fix round, with no reset needed. A lane run that overlapped an outage does not use up a fix round (twice at most).
- Still down after `CREW_SERVICE_WAIT` (300 s): `CONDUCT ENVIRONMENT <names>` (autopilot: `ATTENTION`). Tell the user what is down and the check's output; starting or repairing their services beyond the approved restart command needs their word. Once the check passes (or on their word to try again: a new run gives the restart command fresh attempts), run the conductor or `--detach` again.
- By hand: `crew-services.sh <project> check` (read only).

## Busy machine
- **Heavy gate.** `crew-heavy.sh <project> <command>` runs a command when one of `CREW_HEAVY_SLOTS` (cores/4, at least 1) is free. Lanes are told to send full builds, whole test suites and browser runs through it, and `crew-verify.sh` runs acceptance commands in it. It is advice to a lane, not enforcement. A queued command is never treated as hung, but waiting counts toward the turn's `CREW_MAX_SECS`; after `CREW_HEAVY_WAIT` (1800 s) it exits 75 without running, which says nothing about the code: run it again. The slots are per project: two crews on one machine do not see each other.
- **Saturation.** Load over `CREW_SATURATED_FACTOR` (1.5) x cores: `crew-observe.sh` prints `MACHINE-SATURATED`, the watchdog kills no command as hung (the wall-clock cap still applies), and the conductor rechecks a failed acceptance when the load drops. After `CREW_SATURATED_WAIT` (900 s) it sends the lane a fix round that says to rerun before changing code. A failure from such a window is rerun by a Devin (the conductor or a lane), never by you, before anyone changes code.
- **Lane count.** `crew-doctor.sh` warns, and the architect is told, how many lanes this machine carries when every worktree builds on its own (about 3 cores and 5 GB each). Propose no more than that for compiled or browser-tested stacks.
- **Build cache.** With `sccache` installed, a Rust project's lanes and acceptance runs get `RUSTC_WRAPPER=sccache` and `CARGO_INCREMENTAL=0` (`CREW_BUILD_CACHE=0` off; your own `RUSTC_WRAPPER` wins). A shared `CARGO_TARGET_DIR` is not set up: builds would block on each other's lock and lanes could run each other's binaries. Other toolchains are left as the project configures them.
