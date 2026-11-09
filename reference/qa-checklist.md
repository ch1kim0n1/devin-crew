# Production QA checklist

(`S` = `~/.claude/skills/devin-crew/scripts`)

**Why this exists.** Devin lanes (and `swe-2-flash-high` in particular) are fast, and fast coders optimize for "it runs". They miss details (edge cases, error paths, docs, call sites) and miss the big idea (the thing the user actually wanted). "Done" from a lane means "I stopped". You are the only check between a lane and the user's trust. Never say "it's done" to the user until this checklist is complete for the milestone and every item has evidence.

## Rules of the checklist

1. **Evidence or it did not happen.** Each item ends with `PASS` + the evidence (command and exit code, `file:line`, quoted output), `FAIL` + what, or `N/A` + why. "Looks fine" is not evidence.
2. **Any open HIGH item = FAIL.** MED items: fix, or disclose in the report. Nothing is silently dropped.
3. **Do not trust the DONE line.** It lists what the lane thinks it did. Compare it with the real diff.
4. **Run the thing, not just the tests.** If the change has a user-visible behavior (CLI, endpoint, UI, script), exercise it once the way a user would.
5. **You write down the checklist result** in `.devin-crew/QA.md` under the milestone, then give the verdict.

## A. Mechanical net (2 minutes)

- [ ] `bash S/crew-qa.sh <project>`: HIGH = 0. Every MED reviewed (fixed, or justified in QA.md). It catches stubs, skipped or weakened tests, assertion-free tests, swallowed errors, debug leftovers, secrets, stray files, manifest changes, deleted files. A clean run proves little; it only removes the cheap failures.
- [ ] `bash S/crew-guard.sh <project> check`: no OUTSIDE SCOPE / OVERLAP.
- [ ] `bash S/crew-guard.sh <project> regress`: no new failures vs the baseline.
- [ ] `bash S/lane-msg.sh <project> pending`: no unread mail; no unanswered BLOCKED.

## B. Big idea: did it deliver what the user wanted?

- [ ] **Requirement matrix.** List every requirement from the user's objective and the milestone. For each: the file:line that implements it and the test or run that proves it. A requirement with no row = missing. Fast coders drop whole requirements, not just details.
- [ ] **Surprise test.** Write down 3 things the user would be surprised to find missing or different (docs, migration, config, error message, the second platform, the empty state). Check each.
- [ ] **Size sanity.** Compare diff size with the task. Far smaller than the task implies: something was skipped or stubbed. Far larger: scope creep or generated junk. Both need an explanation.
- [ ] **Right problem.** Reread the original objective, then the diff. Does the change solve the user's problem or a nearby easier one?
- [ ] **Assumptions.** Collect every "assuming", "should work", "simplified", "for now", "could not run" from the lanes' DONE lines and logs. Each becomes a verified fact or a disclosed risk.

## C. Details: correctness

- [ ] **Edge inputs** for each new/changed function or endpoint: empty, null/None, zero, negative, very large, duplicate, unicode/emoji, whitespace-only, malformed. Run at least the ones that can occur.
- [ ] **Error paths**: what happens on bad input, missing file, network failure, timeout, permission denied. Errors reported clearly, not swallowed or turned into silent defaults.
- [ ] **Contract conformance**: signatures, return shapes and error types match CONTRACTS.md. `grep` all call sites of anything whose signature changed; each caller still correct.
- [ ] **State and ordering**: concurrency, idempotency, repeat runs, cleanup of temp files/processes, partial failure leaves a sane state.
- [ ] **Backwards compatibility**: existing callers, data formats, config keys, CLI flags still work unless the task said to break them.
- [ ] **No dead leftovers**: unused imports/functions/files from abandoned attempts; duplicated logic that should call the existing helper.

## D. Tests are real

- [ ] Every new behavior has a test; every fixed bug has a regression test.
- [ ] **Mutation spot-check** (the best test of a Devin test): temporarily break the key line of the implementation (flip a condition, return a constant), rerun the tests. They must fail. If they still pass, the tests are hollow: FAIL. Restore the change afterwards and confirm `git diff` is back to the lane's version.
- [ ] Assertions check results, not "no exception". Expected values come from the contract, not copied from the implementation's output.
- [ ] No test was deleted, skipped, loosened or given a bigger tolerance to get green.
- [ ] Tests do not depend on order, wall clock, network, or the developer's machine paths.

## E. Production concerns

- [ ] **Security**: untrusted input validated at the boundary; no injection (SQL, shell, path traversal, HTML); authz checks present where data is user-specific; no secrets or tokens in code, logs, or fixtures; new dependencies justified.
- [ ] **Performance**: no accidental N+1, unbounded loops or reads of whole large files, missing pagination, blocking calls on hot paths.
- [ ] **Observability**: failures are logged with enough context; no noisy debug logging left; no PII in logs.
- [ ] **Config and ops**: new env vars/flags documented with defaults; migrations reversible or flagged; build, lint and type-check pass, not just tests.
- [ ] **User-facing**: messages are clear and consistent with the product's wording; UI states covered (loading, empty, error); keyboard/accessibility basics for UI. For a UI change, run it and look at it (browser tools), do not infer from code.
- [ ] **Docs**: README / docs / changelog / inline docstrings reflect the new behavior; every example in the docs runs.

## F. Integration of the whole milestone

- [ ] The pieces from different lanes work together: run the real flow end to end in the merged main tree (worktree lanes never saw each other's code).
- [ ] Full test + build + lint run in the main tree after the last merge, compared with the baseline.
- [ ] `git status` of the main tree shows only intended files; no `.devin-crew` leakage, no temp files, no lockfile churn.
- [ ] Independent review lane (`CREW_ROLE=reviewer`) ran; each finding triaged (real -> task, false -> reason in QA.md).

## G. Red flags in a lane's report (each one means dig deeper)

| Signal | Likely truth |
|---|---|
| "could not run" / "should work" / "assuming" | Unverified. Run it yourself. |
| Verify command not literally the one you gave | It verified something easier. |
| DONE lists fewer files than the diff shows (or more) | Scope drift or hidden edits. |
| Tests all pass on the first try | Check mutation spot-check; tests may be hollow. |
| Very short run time for a big task | Part of it was skipped. |
| "Simplified", "for now", "basic version" | The hard part was dropped. |
| Same helper rewritten instead of reused | Duplication; read the surrounding code. |
| Docs describe things the code does not do | Docs written from the plan, not the code. |

## Verdict and the QA.md entry

```
## Milestone <n>: <name>   verdict: PASS | PASS WITH NOTES | FAIL
A mechanical: crew-qa HIGH=0 MED=<n> (<disposition>) | check clean | regress clean
B requirements: <N>/<N> covered (matrix below); surprise test: <3 items checked>
C/D/E: <items failed or N/A with reasons>; mutation spot-check: <what I broke> -> <tests failed as expected>
F integration: <end-to-end command> -> <result>
Open notes for the user: <list or none>
```

FAIL: write each failure as a task in TASKS.md with the exact reproduction, send it to the owning lane (or a new lane), rerun the checklist for that milestone. PASS WITH NOTES: the notes go into the final report word for word. Only PASS or PASS WITH NOTES for every milestone lets you tell the user the work is done.
