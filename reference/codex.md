# Running devin-crew under Codex (or any agent without Claude Code's tools)

Everything in SKILL.md applies. The scripts are plain bash and do not care who runs them. What differs is how the manager launches, waits, notifies and asks. `S` = the `scripts/` folder of this skill.

**Status: written against Codex's documented behavior and the skill layout found on a real Codex install; not yet run end to end under Codex.** The scripts' own flow is covered by the offline suite. If something below does not match your Codex version, trust your tool list and `crew-doctor.sh`, and open an issue.

## 1. Sandbox first (the usual reason it fails)

Lanes are `devin -p` processes started from your shell, so they inherit Codex's sandbox. Devin needs the network and its own data folder (`~/.local/share/devin`). With Codex's default `workspace-write` sandbox the network is off, so every lane would fail. Run `bash S/crew-doctor.sh <project> --trust` first: it fails with the fix if the network is disabled (`CODEX_SANDBOX_NETWORK_DISABLED=1`, best effort) or the Devin data folder is read-only. Choose one in `~/.codex/config.toml`:

```toml
# narrow: workspace-write plus what devin needs
sandbox_mode = "workspace-write"
approval_policy = "on-request"
[sandbox_workspace_write]
network_access = true
writable_roots = ["/Users/<you>/.local/share/devin"]   # absolute path
```

or `sandbox_mode = "danger-full-access"` with `approval_policy = "never"` for a throwaway machine, container or VM. Lanes already run Devin in bypass mode, so the Codex sandbox is the only outer fence; read SECURITY.md. If worktree creation fails on `.git` while the doctor passes, your Codex version protects `.git`: add the repo's `.git` to `writable_roots` or relax the sandbox.

## 2. Tool substitutions

| SKILL.md says | Under Codex |
|---|---|
| Bash with `run_in_background: true` | `bash S/crew-launch.sh <project> lane <lane> - <task_file>` (prefix env such as `CREW_ROLE=tests`): starts detached, returns at once. Router: `bash S/crew-launch.sh <project> router` |
| "wait for the exit notifications, never poll" | `bash S/crew-wait.sh <project> 300`: blocks until a lane exits, a Devin error needs the user, or the router finishes; bounded, reports each event once. Call it again after you have handled the output. Do not call it faster than every few minutes when it times out |
| `PushNotification` | `bash S/crew-notify.sh "<one line, lead with the action>"` (desktop notification, best effort), and put the same line first in your reply |
| `AskUserQuestion` | Ask in plain text, one question |
| Read / Edit / Write | your file tools or `apply_patch` |
| task list tool | `update_plan` |
| `SendUserFile` (stats report) | print the path of `usage/report.html` |
| `ToolSearch`, `Agent` subagents | not needed; the skill never requires subagents (they only appear in test notes) |

`/devin-crew <goal>` is `$devin-crew <goal>` (or pick the skill with `/skills`).

## 3. The loop under Codex

1. Recon and proposal in one reply, Devin count first (SKILL.md phases 1-3). Wait for the user's go.
2. Setup per `reference/execute.md`; `crew-launch.sh` every lane of the wave and the router.
3. `crew-wait.sh <project> 300` in a loop. For each line it prints:
   - `LANE-EXIT <lane> <status>`: read its DONE line, guard check, merge, route mail (execute.md "On each lane exit").
   - `NEEDS-USER <lane> <class>`: tell the user now, run `crew-notify.sh`, wait for their word before `CREW_RETRY_OK=1 bash S/crew-launch.sh ...`. A timed retry (`crew-retry-at.sh`) must itself be started with `crew-launch.sh`-style detaching: `nohup bash S/crew-retry-at.sh <project> <lane> auto >/dev/null 2>&1 &`.
   - `ROUTER ...`: `QUIESCENT` means start QA; `ORCHESTRATOR-MAIL n` means read it and start the router again.
   - `WAIT-TIMEOUT`: nothing new; call again.
   - `NOTHING-RUNNING`: all lanes are idle; decide the next wave or QA.
4. QA, finish and the single final report as in SKILL.md, with `crew-notify.sh` at the end.

If your Codex has multi-agent tools (`spawn_agent`, `wait_agent`), you do not need them here: the workers are Devin processes, not Codex subagents.

## 4. Install

`bash install.sh --codex` (clones into `~/.codex/skills/devin-crew`, or links an existing `~/.claude/skills/devin-crew`). Codex also documents `~/.agents/skills` (user) and `.agents/skills` (per repo); it follows symlinks, so a symlink there works too. `agents/openai.yaml` supplies the display name and default prompt.
