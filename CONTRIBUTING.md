# Contributing

- Run `bash tests/smoke.sh` before every change (offline, a fake `devin`, about 15 s). It must stay green and shellcheck-clean (`shellcheck -S warning scripts/*.sh`).
- Linux: `bash tests/linux-docker.sh` runs the same suite in a container (needs a local Debian/Ubuntu image with bash, git, python3, procps; no network).
- Changes to `SKILL.md` or the rules in `reference/` change how Claude behaves. Re-run the paper scenarios in `tests/pressure-scenarios.md` with a fresh model, and the trigger check in `tests/trigger-prompts.md` if you touch the `description:` line. Add a scenario for a new rule.
- New behavior in a script gets a check in `tests/smoke.sh`. Real Devin error wording goes into `tests/fixtures/real-errors.tsv` with where it was seen.
- Keep scripts portable: no GNU-only flags without a BSD fallback (macOS) and the reverse.
- Keep `SKILL.md` short; detail goes in `reference/`.
