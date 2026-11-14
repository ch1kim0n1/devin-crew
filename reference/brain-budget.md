# Brain budget: where the manager's tokens go and how the crew avoids it

Measured on a real run (one session, 9 milestones): about 900 assistant turns, 455 tool calls (90% Bash), roughly 680k characters of tool output. The visible output is small; the cost is **every turn re-reading the whole conversation**, plus a heavy fixed context (tool and skill lists, hook text) and hand-reviewing diffs the Devins had already produced. The Devin side (free model) was about 280 lane-minutes and cheap.

| Sink | What changed |
|---|---|
| Per-lane exit routine: observe, verify, guard, git diff, board read, merge (6-10 calls, hundreds of lines) | `crew-collect.sh <project> <lane> [--merge]`: one call, about 15 lines, verdict `CLEAN | FIX | BRAIN | WAIT` |
| Launch/wait/resume loop, one brain turn per step | `crew-conduct.sh`: launches all ready tasks, collects, auto-fixes, reviews, merges; the brain wakes once per decision |
| Hand-reading lane diffs and writing probe harnesses | `crew-review.sh`: a read-only reviewer Devin per lane writes at most 15 one-line findings; the lane is resumed with them. The brain reads the findings, not the diff |
| Acceptance run in the wrong tree for worktree lanes | `crew-verify.sh` runs a lane's acceptance inside its worktree (`CREW_VERIFY_IN=proj` for the old behavior) |
| Long session history | Fresh session per milestone: `crew-resume.sh`, `PLAN.md` kept current |

## Rules for the brain
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
