# Git rights for lanes and for you

(`S` = the `scripts/` folder of this skill; see SKILL.md)

**Default: nobody commits or pushes.** Worktree merges leave uncommitted edits in the main tree. Ask in the proposal whether lanes should commit/push; default no.

## Who authorizes

The user's instruction in chat ("have them commit", "commit and push to origin main") or a standing instruction in their memory/CLAUDE.md to commit and push regularly. No instruction to commit means none to push. Never force-push.

## Shared-tree mode (lanes work in the project itself)

Set at the lane's **first launch** only:
- `CREW_GIT=commit`: the lane stages explicit paths inside its own scope (never `git add -A`), commits after its verify command passes with a `[crew:<lane>]` message, and does not push.
- `CREW_GIT=push CREW_GIT_TARGET="<remote> <branch>"`: as above, then one plain `git push <remote> <branch>`; on non-fast-forward one `git pull --rebase` then push again; a second failure or any conflict is `BLOCKED`. The user must have named remote and branch; without a valid target the script falls back to commit-only.

`devin-lane.sh` refuses the setting in a worktree, in a non-git folder, and for a resumed lane (it keeps the rights it started with). `devin-lane.sh --print ...` shows which rights a launch would get.

## Worktree mode

A lane commit inside a detached worktree would hide its changes from `crew-worktree.sh merge` and would never reach the repo, so lanes never commit there. You commit in the main tree after `merge` and QA PASS, and push only if the user said to.

## Cadence (when git is allowed)

Commit at each verified unit of work (a lane task, a milestone after QA PASS); push after each milestone. Never one giant commit at the end, never a commit per tiny edit.
