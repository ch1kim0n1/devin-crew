# AGENTS.md

This repo is the `devin-crew` skill (for Claude Code and Codex). Guidance for any coding agent working on it:

- Test before and after every change: `bash tests/smoke.sh` (offline, a fake `devin`) and `shellcheck -S warning scripts/*.sh install.sh`. Linux: `bash tests/linux-docker.sh`.
- Scripts must run on macOS and Linux bash (no GNU-only flags without a BSD fallback).
- Behavior Claude/Codex follows lives in `SKILL.md` and `reference/`; keep `SKILL.md` short, put detail in `reference/`. After changing those rules, re-run the paper scenarios in `tests/pressure-scenarios.md`.
- Using the skill rather than editing it? Read `SKILL.md`, and `reference/codex.md` if you are Codex.
- Never commit `usage/`, `MODEL`, `AUTONOMY`, or any `.devin-crew/` folder.
