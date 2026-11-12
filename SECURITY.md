# Security

## What this skill can do on your machine

Lanes run `devin -p` in **bypass mode** (`--permission-mode dangerous`): Devin approves its own tool calls, so a lane can run any shell command and edit any file your user can. This is needed because headless Devin cannot answer prompts. The protections are guardrails, not a sandbox:

- file scopes and the lane preamble (instructions the model can ignore),
- a git worktree per lane, or a pre-launch snapshot (so you can undo),
- a scope check after each lane (`crew-guard.sh check`),
- no git writes by default; commit/push only when you say so, never force-push.

Do **not** run it on a machine or folder holding secrets you cannot lose or leak, on a repo with uncommitted work you have not backed up, or against production systems. Run it in a throwaway clone first. For stronger isolation run it inside a container or VM.

## Data

- Everything stays local. The skill sends nothing anywhere; Devin itself talks to Cognition's servers as it normally does.
- `.devin-crew/` in your project holds plans, logs, mail and Devin session ids. It is git-ignored by the skill's instructions; check yours.
- The cross-project usage ledger is `usage/ledger.tsv` inside the skill folder (project paths, lane names, timings, token estimates). It is git-ignored. Delete the file to erase it.

## Reporting a vulnerability

Open a private security advisory on the GitHub repository (Security tab, "Report a vulnerability"), or an issue without exploit details asking for a contact. Please do not post working exploits publicly first.
