# Brain budget: where the manager's tokens go and how the crew avoids it

Measured on a real run (one session, 9 milestones): about 900 assistant turns, 455 tool calls (90% Bash), roughly 680k characters of tool output. The visible output is small; the cost is **every turn re-reading the whole conversation**, plus a heavy fixed context (tool and skill lists, hook text) and hand-reviewing diffs the Devins had already produced. The Devin side (free model) was about 280 lane-minutes and cheap.

| Sink | What changed |
|---|---|
| Per-lane exit routine: observe, verify, guard, git diff, board read, merge (6-10 calls, hundreds of lines) | `crew-collect.sh <project> <lane> [--merge]`: one call, about 15 lines, verdict `CLEAN | FIX | BRAIN | WAIT` |
| Launch/wait/resume loop, one brain turn per step | `crew-conduct.sh`: launches all ready tasks, collects, auto-fixes, reviews, merges; the brain wakes once per decision |
| Hand-reading lane diffs and writing probe harnesses | `crew-review.sh`: a read-only reviewer Devin per lane writes at most 15 one-line findings; the lane is resumed with them. The brain reads the findings, not the diff |
| Acceptance run in the wrong tree for worktree lanes | `crew-verify.sh` runs a lane's acceptance inside its worktree (`CREW_VERIFY_IN=proj` for the old behavior) |
| Long session history | Fresh session per milestone: `crew-resume.sh`, `PLAN.md` kept current |

## Measured on a second look (codily run, 1,252 brain turns, Claude Code)
The brain used 408M cache-read tokens against 211M for all 28 Devin lanes. Where it went: one session never reset (context 95k at turn 1, 669k at the end); 219 build/test/audit runs and 289 greps by the brain itself; 468 manual lane-steering calls (the conductor was never started); 93 plan and 91 wrap-up calls re-reading the full context. A stale Codex install lacked the conductor, collect and reviewer scripts entirely.

| Sink | What changed (1.3.0) |
|---|---|
| Brain running tests, audits, builds, edits | Forbidden by the Brain contract: a Devin lane does it (implementer, tests, docs, refactor) |
| Milestone QA by the brain (checklist, mutation check, diff reading) | `crew-audit.sh qa`: a read-only QA Devin writes the verdict; the conductor starts it and puts it in the digest |
| Final report written by the brain | `crew-conduct.sh <project> --report`: a reporter Devin writes `REPORT.md` |
| 6-8 setup calls | `crew-init.sh`: one call |
| Session never renewed | Conductor prints `FRESH-SESSION` after `CREW_FRESH_AFTER` (12) wakes; `crew-resume.sh` restarts the count |
| Stale install silently lacks the lanes | `crew-doctor.sh` warns on a missing script; `install.sh --codex` links instead of keeping a copy |
| Recon, plan, briefs, contracts written by the brain | `crew-plan.sh`: a read-only architect Devin drafts all of it; the brain reads one page and asks at most 3 questions |
| Brain steering milestone after milestone, fixing QA findings | `crew-autopilot.sh`: milestones, QA, fix rounds, final QA, report, branch + PR in one detached process; the brain wakes once at the end |
| Did the brain stay a conductor? | `crew-brain-stats.sh <project>`: brain tokens vs Devin tokens, violations (tests/builds/edits by the brain), context size |

## Rules for the brain
0. The brain decides and deploys; it never runs project commands or edits project files. If you are about to type `cargo test`, `npm test`, a linter or `sed -i` on project code, write a brief instead.
1. Start with the digest. `crew-collect.sh` says what is wrong in one line (`VERDICT FIX (acceptance failed)`); act on that, do not reconstruct it.
2. Read raw code only where a digest or finding points, and only the top few files. Re-read nothing a reviewer cleared unless the area is security, parsing, concurrency or money.
3. Write briefs once, carefully (exact verify command, owned files, definition of done): a good brief saves more brain tokens than any review step. A planning mistake shows up as `OUTSIDE SCOPE` in collect: fix `scopes.txt` before the next wave.
4. One Bash call per decision: chain read-only commands, redirect long output to a file and read the tail.
5. Never poll. The conductor and the background-exit notification are the only reasons to wake.
6. Past about 150 tool calls in a session, finish the milestone, update `PLAN.md`, and suggest a fresh session.

## Keeping Devins busy (utilization)
- Lane count = independent file clusters, cap 5. A lane with a chain of tasks (`depends`) stays busy while others finish.
- The conductor launches every ready task at once and starts a reviewer Devin as soon as a lane is clean, while other lanes keep running.
- Idle time is the brain reading. Move reading into reviewers; use `CREW_AUTOREVIEW=1` (default), `CREW_REVIEW_PASSES=2`, `CREW_AUTOFIX=2`.
- Parallelism below 1 in `/devin-crew stats` means lanes wait on the brain: look for missing briefs (`STUCK ... no brief`) and long manual review gaps.

## Conductor reference
`crew-conduct.sh <project> [--status | --reset <lane> [state]]`; env `CREW_AUTOFIX`, `CREW_AUTOREVIEW`, `CREW_REVIEW_PASSES`, `CREW_MERGE`, `CREW_CONDUCT_MAX_LANES`, `CREW_CONDUCT_POLL`, `CREW_CONDUCT_MAX_SECS`. State per lane in `.devin-crew/conduct/<lane>.state` (launched, reviewing, merged, brain). It adopts lanes you launched by hand (task running/review/failed, no state). It never retries a Devin error (NEEDS-USER) and never merges a lane with a scope violation, merge conflict or exhausted fix rounds.
