# Real-Devin runs (not automated; kept as evidence of what was exercised)

## 2026-11-09, trial: 3 lanes + reviewer, shared and worktree modes, scratch git repo
Parallel lanes, resume, mail pickup and wake, worktree add/merge/remove, scope check, snapshot/restore, hung-command kill (`sleep 240` killed at about 90 s), a real 11-minute empty-reply stall detected and recovered by nudge in 20 s. 25 tests, 4 mutations caught, reviewer read-only. Verdict PASS WITH NOTES.

## 2026-11-10, 5 lanes + reviewer, worktree mode, scratch "taskboard" CLI (Python, ~1000 lines incl. tests)
Setup: `crew-doctor.sh --trust`, PLAN.md, 5 contract-first briefs, budget 20 lane-minutes, `crew-router.sh` started with the wave.
- Wave 1 (5 lanes in parallel, about 3.5 min): all done; 5 tasks moved to `review` automatically. A deliberately injected `sleep 300` in one lane was killed by the watchdog after 75 s and the lane carried on.
- Merge: the deliberate `README.md` overlap (two lanes owning it) surfaced as a whole-patch conflict. Found and fixed afterwards: scope-overlap lint (`crew-guard.sh scopes`), OVERLAP in worktree `check`, per-file partial merge, bytecode noise.
- Integration: cli tests (never runnable in the cli lane's own checkout) passed after merge; 52 tests.
- Contract v2 (due dates) mid-run: bumped CONTRACTS.md, `ack-contract` for the unaffected lane, refreshed 4 worktrees (remove + add at the same path, sessions continued), mailed the 4 affected lanes, router woke them all, all done in 2 min. Found and fixed: `crew-verify.sh` missed an off-format `DONE lane (v2):` line; the wake prompt now demands the exact DONE format. 72 tests.
- QA: verify clean, `crew-qa.sh` clean, manual end-to-end (legacy 4-key data file, bad date exit 2, unknown id exit 1), mutation spot-check 7/7 caught, reviewer lane (read-only, tree byte-identical afterwards) found 12 issues, 3 MED reproduced by hand. Verdict PASS WITH NOTES; findings recorded in QA history (watch list: error-path 3x).
- Budget: 16 of 20 lane-minutes (80% warning fired). Total lane run time about 17 minutes.

Not exercised in a real run: an empty-reply stall after the per-turn cap change, Linux, a project larger than a few thousand lines, shared-tree mode with 5 lanes.
