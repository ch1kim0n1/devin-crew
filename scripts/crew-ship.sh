#!/usr/bin/env bash
# Deliver the crew's verified work: crew branch, commit, push, pull request. Plain git and gh only; never main, never force.
#   bash crew-ship.sh <project> [all]  [--base <branch>] [--draft] [--print]   commit + push + PR (default)
#   bash crew-ship.sh <project> commit "<message>"                             commit on the crew branch only (e.g. after each milestone)
#   bash crew-ship.sh <project> pr [--base <branch>] [--draft]                 push the crew branch and open the PR
#   bash crew-ship.sh <project> --print                                        dry run: what would happen, changes nothing
# Draft PRs: --draft, `pr: draft` in .devin-crew/PLAN.md, or CREW_PR_DRAFT=1.
#   bash crew-ship.sh <project> task <task-id> [--base <branch>] [--draft] [--print]   per-task mode: one branch and PR per task
# Per-task mode (`ship: per-task` in PLAN.md, or CREW_SHIP=per-task plus CREW_SHIP_OK=1): the task's in-scope changes are committed in its
# lane's worktree on `issue-<n>-<slug>` (a line `issue: <n>` in prompts/<task-id>.md; else `crew/<task-id>-<slug>`), pushed, and opened as
# a PR with `Closes #<n>`; the task turns `pr` until the PR merges. Rerun after review fixes: same branch, same PR, a new [lane-x] comment.
# What counts as verified there is the task's own acceptance command, rerun here (no whole-run QA verdict per PR). `all` then ships nothing.
# Authorization: the user said (chat) to push a branch and open a PR. Without CREW_SHIP_OK=1 (or `ship: yes` in .devin-crew/PLAN.md) this refuses
# everything except --print. Refuses when the newest QA verdict is missing or FAIL (CREW_SHIP_UNVERIFIED=1 is the user's override), when the
# added lines look like secrets, when there is no remote, or when gh is not logged in. The branch is crew/<slug> (never the base branch).
# PR body: .devin-crew/REPORT.md (else a stub from PLAN.md). Output: the PR URL on the last line, `SHIP OK <url>`.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
shift; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"
mode=all; base=""; draft=""; dry=0; msg=""
case "${1:-}" in all|commit|pr|task) mode=$1; shift;; esac
[ "$mode" = commit ] && { msg=${1:-}; shift; }
tid=""; [ "$mode" = task ] && { tid=${1:-}; shift; }
while [ $# -gt 0 ]; do case "$1" in --base) base=$2; shift 2;; --draft) draft=--draft; shift;; --print) dry=1; shift;; *) shift;; esac; done
# `pr: draft` in PLAN.md (or CREW_PR_DRAFT=1) opens the PR as a draft: the user's word, even mid-run.
{ [ "${CREW_PR_DRAFT:-0}" = 1 ] || grep -qiE '^pr: *draft' "$crew/PLAN.md" 2>/dev/null; } && draft=--draft
stop() { echo "SHIP STOP: $*"; exit 1; }
git -C "$proj" rev-parse --show-toplevel >/dev/null 2>&1 && [ "$(git -C "$proj" rev-parse --show-toplevel)" = "$proj" ] || stop "$proj is not a git repo root"
auth=${CREW_SHIP_OK:-0}; grep -qiE '^ship: *(yes|per-task)' "$crew/PLAN.md" 2>/dev/null && auth=1
[ "$auth" = 1 ] || [ "$dry" = 1 ] || stop "not authorized: the user must say to push a branch and open a PR (CREW_SHIP_OK=1 or 'ship: yes' in PLAN.md)"
secrets_gate() { # stdin: a diff of what is about to be committed; $1: its file names. Reports file:line, never the value.
  local hits envf
  hits=$(awk '/^\+\+\+ /{f=substr($2,3)} /^@@/{split($3,a,","); n=substr(a[1],2)-1} /^\+[^+]/{n++; if ($0 ~ /(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{20,}|(api[_-]?key|secret|password|token)[A-Za-z0-9_]*["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9+\/_-]{20,})/) print f ":" n}' | sort -u | head -8)
  envf=$(printf '%s\n' "$1" | grep -E '(^|/)\.env($|\.)|\.pem$|id_rsa' | head -5)
  [ -z "$hits$envf" ] || { printf '%s\n' "$hits" "$envf" | grep . | sed 's/^/  possible secret: /'; stop "secrets scan: remove these from the change (or move them to ignored config) and rerun"; }
}
need_gh() { # $1: where the commit is kept
  git -C "$proj" remote get-url origin >/dev/null 2>&1 || stop "no remote 'origin': add one, then rerun ($1)"
  command -v gh >/dev/null 2>&1 || stop "gh is not installed ($1)"
  gh auth status >/dev/null 2>&1 || stop "gh is not logged in: run 'gh auth login' ($1)"
}
push_branch() { # dir branch; never forced
  local out; out=$(git -C "$1" push -u origin "$2" 2>&1) || stop "push failed (a non-fast-forward is never forced; resolve it, then rerun): $(printf '%s' "$out" | tail -3)"
  printf '%s\n' "$out" | tail -2
}
create_pr() { # base head title body_file -> URL
  local out; out=$(cd "$proj" && gh pr create --base "$1" --head "$2" --title "$3" --body-file "$4" $draft 2>&1) || { echo "$out" | tail -3; return 1; }
  local url; url=$(printf '%s\n' "$out" | grep -Eo 'https://[^ ]+/pull/[0-9]+' | tail -1)
  [ -n "$url" ] || { echo "gh pr create printed no PR url:"; printf '%s\n' "$out" | tail -3; return 1; }
  printf '%s\n' "$url"
}

if [ "$mode" = task ]; then
  [ -n "$tid" ] || stop "usage: crew-ship.sh <project> task <task-id>"
  bash "$here/crew-pr.sh" "$proj" mode || stop "per-task shipping is off: it needs 'ship: per-task' in PLAN.md (or CREW_SHIP=per-task)"
  IFS=$'\t' read -r lane tstatus acc < <(bash "$here/crew-tasks.sh" "$proj" row "$tid")
  [ -n "${lane:-}" ] || stop "no task '$tid' in TASKS.md"
  wt=$(cat "$crew/lanes/$lane.workdir" 2>/dev/null)
  { [ -n "$wt" ] && [ "$wt" != "$proj" ] && [ -d "$wt" ]; } || stop "lane $lane has no worktree: per-task shipping needs worktree mode"
  [ -n "$base" ] || base=$(bash "$here/crew-pr.sh" "$proj" base)
  brief="$crew/prompts/$tid.md"
  issue=$(sed -n 's/^[[:space:]]*[Ii]ssue:[[:space:]]*#\{0,1\}\([0-9][0-9]*\).*/\1/p' "$brief" 2>/dev/null | head -1)
  title=$(grep -vE '^[[:space:]]*([Ii]ssue:.*)?$' "$brief" 2>/dev/null | head -1 | sed 's/^#* *//' | cut -c1-70); title=${title:-crew task $tid}
  slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//' | cut -c1-40 | sed 's/-$//')
  if [ -n "$issue" ]; then want="issue-$issue-${slug:-$tid}"; else want="crew/$tid-${slug:-work}"; fi
  prd="$crew/pr"; mkdir -p "$prd"; branch=$(cat "$prd/$tid.branch" 2>/dev/null); url=$(cat "$prd/$tid.url" 2>/dev/null)
  if [ "$dry" = 1 ]; then echo "SHIP DRY RUN: task $tid (lane $lane) -> branch ${branch:-$want}, base $base, ${issue:+Closes #$issue, }PR ${url:-new}, authorized: $auth"; exit 0; fi
  [ "$auth" = 1 ] || stop "not authorized: the user must say to push branches and open PRs (CREW_SHIP_OK=1 or 'ship: per-task' in PLAN.md)"
  if [ "${CREW_SHIP_UNVERIFIED:-0}" != 1 ]; then
    case "$tstatus" in review|"done") ;; *) stop "task $tid is '$tstatus': only a finished task is shipped (the user can override with CREW_SHIP_UNVERIFIED=1)";; esac
    v=$(bash "$here/crew-verify.sh" "$proj" "$lane" 2>&1) || { printf '%s\n' "$v" | tail -8; stop "task $tid is not verified: nothing unverified is shipped"; }
  fi
  globs=(); while IFS=$'\t' read -r l g || [ -n "$l" ]; do [ "$l" = "$lane" ] && globs+=("$g"); done < "$crew/scopes.txt"
  [ ${#globs[@]} -gt 0 ] || stop "$lane has no scope in scopes.txt"
  excl=(":!node_modules" ":!.venv" ":!venv" ":(exclude,glob)**/__pycache__/**" ":(exclude,glob)**/*.pyc" ":(exclude,glob)**/.DS_Store")
  git -C "$wt" add -N -- . "${excl[@]}" 2>/dev/null
  # --no-renames: a moved file must list both paths, or its old copy stays in the PR
  tfiles=(); while IFS= read -r -d '' f; do tfiles+=("$f"); done < <(git -C "$wt" diff HEAD --no-renames --name-only -z -- "${globs[@]}")
  git -C "$proj" fetch -q origin "$base" 2>/dev/null || stop "cannot fetch origin/$base"
  cur=$(git -C "$wt" symbolic-ref --short -q HEAD || echo "")
  if [ -z "$branch" ]; then
    # a new PR must contain this task only: the worktree has to sit on a commit the base already has
    git -C "$wt" merge-base --is-ancestor HEAD "origin/$base" 2>/dev/null || stop "lane $lane's worktree holds commits that are not on $base (an earlier task?): run crew-worktree.sh $proj rebase $lane first"
    branch=$want; n=1
    while git -C "$proj" show-ref --verify -q "refs/heads/$branch" || git -C "$proj" show-ref --verify -q "refs/remotes/origin/$branch"; do n=$((n + 1)); branch="$want-$n"; done
    git -C "$wt" checkout -q -b "$branch" || stop "cannot create branch $branch"
    echo "$branch" > "$prd/$tid.branch"
  elif [ "$cur" != "$branch" ]; then
    git -C "$wt" checkout -q "$branch" || stop "cannot switch the worktree to $branch"
  fi
  # Empty the index first (`add -N` stages deletions, in scope or not), then stage exactly the lane's files. update-index, unlike
  # `git add`, also accepts a path that was deleted or moved away.
  git -C "$wt" reset -q || stop "git reset (index only) failed in $wt"
  [ ${#tfiles[@]} -eq 0 ] || printf '%s\0' "${tfiles[@]}" | git -C "$wt" update-index --add --remove -z --stdin || stop "staging failed in $wt"
  if ! git -C "$wt" diff --cached --quiet; then
    secrets_gate "$(git -C "$wt" diff --cached --name-only)" < <(git -C "$wt" diff --cached -U0 --no-color)
    git -C "$wt" commit -q -m "$title" -m "devin-crew task $tid${issue:+, refs #$issue}" >/dev/null 2>&1 || stop "git commit failed in $wt (hook or identity)"
  fi
  if [ "$(git -C "$wt" rev-list --count "origin/$base..HEAD")" = 0 ]; then
    bash "$here/crew-tasks.sh" "$proj" set "$tid" "done"; echo "SHIP NOCHANGE $tid: nothing differs from $base, no PR"; exit 0
  fi
  need_gh "the commit is kept on $branch"
  push_branch "$wt" "$branch"
  if [ -z "$url" ]; then
    bf="$prd/$tid.body.md"
    { [ -n "$issue" ] && printf 'Closes #%s\n\n' "$issue"
      echo "Task \`$tid\` (lane \`$lane\`) from a devin-crew run."
      echo "Verified locally: \`$acc\`"
      grep -E "DONE $lane( |:|\()" "$crew/BOARD.md" 2>/dev/null | tail -1; } > "$bf"
    url=$(create_pr "$base" "$branch" "$title" "$bf") || stop "gh pr create failed: $url"
    echo "$url" > "$prd/$tid.url"
  fi
  bash "$here/crew-tasks.sh" "$proj" set "$tid" pr
  bash "$here/crew-pr.sh" "$proj" comment "$url" "$lane" "ready for review: $tid at $(git -C "$wt" rev-parse --short HEAD)" >/dev/null 2>&1 || echo "WARN could not post the ready-for-review comment on $url"
  echo "SHIP OK $url"; exit 0
fi
if bash "$here/crew-pr.sh" "$proj" mode; then
  echo "per-task mode: each task has its own PR (crew-ship.sh $proj task <id>); nothing else to ship"; cat "$crew"/pr/*.url 2>/dev/null; exit 0
fi

cur=$(git -C "$proj" symbolic-ref --short -q HEAD || echo "")
default=$(git -C "$proj" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -n "$default" ] || { for b in main master; do git -C "$proj" show-ref --verify -q "refs/heads/$b" && { default=$b; break; }; done; }
base=${base:-${default:-main}}
slug=$(sed -n '1,/^## /p' "$crew/PLAN.md" 2>/dev/null | grep -iE '^(#|objective|goal)' | head -1 | sed -E 's/^#+ *//; s/^(objective|goal): *//I' | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40)
branch="crew/${slug:-work}"
case "$cur" in crew/*) branch=$cur;; esac
title=$(grep -iE '^#* *(objective|goal):' "$crew/PLAN.md" 2>/dev/null | head -1 | sed -E 's/^#* *[A-Za-z]+: *//' | cut -c1-70); title=${title:-crew: ${slug:-work}}
files=$(git -C "$proj" status --porcelain --untracked-files=all | sed -E 's/^.{3}//; s/.* -> //' | grep -v '^\.devin-crew/' | grep -vE '(^|/)(node_modules|__pycache__|\.venv|target|dist|build)/' )
pre="$crew/prework.files"   # files that were already dirty before the crew started belong to the user: ship them only if a lane scope covers them
in_scope() { local f=$1 g; while IFS=$'\t' read -r _ g || [ -n "$g" ]; do
  # shellcheck disable=SC2254
  case "$f" in $g) return 0;; esac; done < "$crew/scopes.txt"; return 1; }
if [ -s "$pre" ] && [ -f "$crew/scopes.txt" ]; then
  keep=""; while IFS= read -r f; do [ -z "$f" ] && continue
    if grep -qxF -- "$f" "$pre" && ! in_scope "$f"; then continue; fi
    keep="$keep$f"$'\n'; done <<< "$files"
  files=${keep%$'\n'}
fi
nfiles=$(printf '%s' "$files" | grep -c . || true)
verdict=$(bash "$here/crew-audit.sh" "$proj" verdict 2>/dev/null | head -1); bash "$here/crew-audit.sh" "$proj" verdict >/dev/null 2>&1; vrc=$?
if [ "$dry" = 1 ]; then
  echo "SHIP DRY RUN: branch $branch (from ${cur:-detached}), base $base, $nfiles changed file(s), title \"$title\", QA verdict: ${verdict:-none}, authorized: $auth"
  git -C "$proj" remote get-url origin >/dev/null 2>&1 && echo "remote: origin" || echo "remote: NONE (push would refuse)"
  exit 0; fi
[ "$vrc" = 0 ] || [ "${CREW_SHIP_UNVERIFIED:-0}" = 1 ] || stop "newest QA verdict is '${verdict}': nothing unverified is shipped (run QA; the user can override with CREW_SHIP_UNVERIFIED=1)"

do_commit() {
  [ "$nfiles" -gt 0 ] || { echo "nothing to commit"; return 0; }
  secrets_gate "$files" < <(git -C "$proj" diff HEAD -U0 --no-color -- . ':!.devin-crew' 2>/dev/null
    git -C "$proj" ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do case "$f" in (.devin-crew/*) continue;; esac; git -C "$proj" diff --no-index -U0 --no-color /dev/null "$f" 2>/dev/null; done)
  grep -qxF '.devin-crew/' "$proj/.git/info/exclude" 2>/dev/null || echo '.devin-crew/' >> "$proj/.git/info/exclude"
  if [ "$cur" != "$branch" ]; then git -C "$proj" checkout -q -b "$branch" 2>/dev/null || git -C "$proj" checkout -q "$branch" || stop "cannot switch to $branch"; fi
  printf '%s\n' "$files" | while IFS= read -r f; do [ -n "$f" ] && git -C "$proj" add -A -- "$f"; done
  git -C "$proj" diff --cached --quiet >/dev/null 2>&1 && { echo "nothing staged"; return 0; }
  body="${msg:-$title}"
  git -C "$proj" commit -q -m "$body" -m "Built by a devin-crew run (QA: ${verdict:-n/a})." >/dev/null 2>&1 || stop "git commit failed"
  echo "committed on $branch: $(git -C "$proj" rev-parse --short HEAD) ($nfiles files)"
}
do_pr() {
  need_gh "the branch is committed locally on $branch"
  b=$(git -C "$proj" symbolic-ref --short -q HEAD); case "$b" in "$base"|main|master) stop "refusing to push the base branch ($b)";; esac
  push_branch "$proj" "$b"
  bf="$crew/REPORT.md"; [ -s "$bf" ] || { bf="$crew/pr-body.md"; { echo "## Objective"; sed -n '1,25p' "$crew/PLAN.md" 2>/dev/null; echo; echo "QA verdict: ${verdict:-n/a}"; } > "$bf"; }
  url=$(create_pr "$base" "$b" "$title" "$bf") || stop "gh pr create failed: $url"
  echo "SHIP OK $url"; echo "$url" > "$crew/PR_URL"
}
case "$mode" in commit) do_commit;; pr) do_pr;; all) do_commit; do_pr;; esac
