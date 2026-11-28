# GitHub flows: one PR per task, the review loop, waiting on issues

(`S` = the `scripts/` folder of this skill; see SKILL.md)

## Per-task PRs (repos that require a branch and PR per issue)
On only with the user's word, because it pushes and opens PRs on its own: `crew-plan.sh <project> go --ship-per-task` (writes `ship: per-task` in PLAN.md), or `CREW_SHIP=per-task` **plus** `CREW_SHIP_OK=1`. Needs a git repo root with `origin`, checked out on the base branch (origin's default; `base: <branch>` in PLAN.md or `CREW_BASE_BRANCH` overrides), and `gh auth login`.

- A line `issue: <n>` in `prompts/<task-id>.md` gives branch `issue-<n>-<slug>` and `Closes #<n>` in the PR body; without it `crew/<task-id>-<slug>`. The first other line of the brief is the PR title. GitHub closes the issue only when the PR merges into the default branch.
- Each lane worktree is cut from `origin/<base>`. A verified, reviewed task is committed there (secrets scan), pushed (never forced) and opened as a PR by `crew-ship.sh <project> task <id>`; the task turns `pr`. Verification is the task's acceptance command; there is no whole-run QA verdict per PR (the milestone QA still runs after everything merged).
- `done` means merged. Tasks that depend on it wait, and the same lane starts nothing new until its PR merges (its worktree is kept for review fixes), so give independent work separate lanes. The next task starts from the updated base; the conductor fast-forwards the project's base branch for QA.
- `crew-ship.sh <project> all`, local merges and best-of-2 races are off in this mode. Edits a lane makes when mail wakes it while its PR is open go out only with its next push.

## Review loop (plain comments with markers)
GitHub refuses a review of your own PR, and manager and Devins usually share one account, so the protocol is comments:

- the crew posts `[lane-<lane>] ready for review: ...` after each push;
- the manager (you, or the user) answers with a comment starting `[manager]`, or merges;
- on a newer `[manager]` comment the conductor resumes the lane with its text, pushes the fix to the same PR and posts ready again (at most `CREW_PR_ROUNDS`=5 per task).

Only comments by the `gh` account itself or the repo's OWNER / MEMBER / COLLABORATOR count: the text goes to a lane that runs with all tools approved. Review submissions and inline review comments are not read.

The conductor ends with `PR-WAIT` when only open PRs or issues are left (the autopilot writes `ATTENTION`). Review is the user's, or a read-only reviewer lane's whose findings you relay (the Brain contract still holds: you do not read the diffs). Show the user the PRs it lists, post with `crew-pr.sh <project> comment <pr> manager "<text>"` or merge (merging and commenting need the user's word, like any outward action), then start the conductor / autopilot again. To block until a lane is waiting for you: `crew-pr.sh <project> watch --max 3600` as a background task. A PR closed without merging stops that lane (`BRAIN`) and reopens its task: after the user's word, `crew-conduct.sh <project> --reset <lane> merged` retries it on a new branch, or remove the row.

## Waiting on issues
`#<n>` in a task's `depends` cell holds it until that issue is closed (works in every mode). For hand-built flows a lane can block on GitHub itself: `crew-pr.sh <project> wait --lane <lane> pr:<n> issue:<n>` returns on a merged or closed PR, a new `[manager]` comment, or a closed issue (exit 3 after 900 s: call again; longer waits trip the hung-command watchdog). Say so in the lane's brief; lanes use it only when told to.

## Visible lanes (`CREW_LANE_UI`)
`tmux` (Linux or macOS; `tmux attach -t crew`, or a window in the current tmux session), `terminal` or `iterm` (macOS, a new window per lane turn). The lane is an interactive `devin --prompt-file` session; worktree, brief, git rights, guards and the budget are unchanged. The turn ends when the lane posts its DONE line (the session is closed `CREW_UI_GRACE`=30 s later) or the session exits. Not available: stall watchdog and nudges, lane log, `--export`, and most error classification (a usage limit shows in the window, not to you); observe through the session store and file times. `CREW_MAX_SECS` still caps a turn, so raise it if the user will be typing. Set the variable on `go` and again whenever you restart the autopilot or conductor. A tmux window inherits the tmux server's environment (proxy or `DEVIN_*` variables set only in your shell do not reach it).
