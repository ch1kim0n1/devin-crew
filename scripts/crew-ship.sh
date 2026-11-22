#!/usr/bin/env bash
# Deliver the crew's verified work: crew branch, commit, push, pull request. Plain git and gh only; never main, never force.
#   bash crew-ship.sh <project> [all]  [--base <branch>] [--draft] [--print]   commit + push + PR (default)
#   bash crew-ship.sh <project> commit "<message>"                             commit on the crew branch only (e.g. after each milestone)
#   bash crew-ship.sh <project> pr [--base <branch>] [--draft]                 push the crew branch and open the PR
#   bash crew-ship.sh <project> --print                                        dry run: what would happen, changes nothing
# Authorization: the user said (chat) to push a branch and open a PR. Without CREW_SHIP_OK=1 (or `ship: yes` in .devin-crew/PLAN.md) this refuses
# everything except --print. Refuses when the newest QA verdict is missing or FAIL (CREW_SHIP_UNVERIFIED=1 is the user's override), when the
# added lines look like secrets, when there is no remote, or when gh is not logged in. The branch is crew/<slug> (never the base branch).
# PR body: .devin-crew/REPORT.md (else a stub from PLAN.md). Output: the PR URL on the last line, `SHIP OK <url>`.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
shift; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"
mode=all; base=""; draft=""; dry=0; msg=""
case "${1:-}" in all|commit|pr) mode=$1; shift;; esac
[ "$mode" = commit ] && { msg=${1:-}; shift; }
while [ $# -gt 0 ]; do case "$1" in --base) base=$2; shift 2;; --draft) draft=--draft; shift;; --print) dry=1; shift;; *) shift;; esac; done
stop() { echo "SHIP STOP: $*"; exit 1; }
git -C "$proj" rev-parse --show-toplevel >/dev/null 2>&1 && [ "$(git -C "$proj" rev-parse --show-toplevel)" = "$proj" ] || stop "$proj is not a git repo root"
auth=${CREW_SHIP_OK:-0}; grep -qiE '^ship: *yes' "$crew/PLAN.md" 2>/dev/null && auth=1
[ "$auth" = 1 ] || [ "$dry" = 1 ] || stop "not authorized: the user must say to push a branch and open a PR (CREW_SHIP_OK=1 or 'ship: yes' in PLAN.md)"
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
  # secrets: added lines only; report file:line, never the value
  hits=$( { git -C "$proj" diff HEAD -U0 --no-color -- . ':!.devin-crew' 2>/dev/null
            git -C "$proj" ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do case "$f" in .devin-crew/*) continue;; esac; git -C "$proj" diff --no-index -U0 --no-color /dev/null "$f" 2>/dev/null; done; } \
    | awk '/^\+\+\+ /{f=substr($2,3)} /^@@/{split($3,a,","); n=substr(a[1],2)-1} /^\+[^+]/{n++; if ($0 ~ /(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{20,}|(api[_-]?key|secret|password|token)[A-Za-z0-9_]*["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9+\/_-]{20,})/) print f ":" n}' | sort -u | head -8)
  envf=$(printf '%s\n' "$files" | grep -E '(^|/)\.env($|\.)|\.pem$|id_rsa' | head -5)
  [ -z "$hits$envf" ] || { printf '%s\n' "$hits" "$envf" | grep . | sed 's/^/  possible secret: /'; stop "secrets scan: remove these from the change (or move them to ignored config) and rerun"; }
  grep -qxF '.devin-crew/' "$proj/.git/info/exclude" 2>/dev/null || echo '.devin-crew/' >> "$proj/.git/info/exclude"
  if [ "$cur" != "$branch" ]; then git -C "$proj" checkout -q -b "$branch" 2>/dev/null || git -C "$proj" checkout -q "$branch" || stop "cannot switch to $branch"; fi
  printf '%s\n' "$files" | while IFS= read -r f; do [ -n "$f" ] && git -C "$proj" add -A -- "$f"; done
  git -C "$proj" diff --cached --quiet >/dev/null 2>&1 && { echo "nothing staged"; return 0; }
  body="${msg:-$title}"
  git -C "$proj" commit -q -m "$body" -m "Built by a devin-crew run (QA: ${verdict:-n/a})." >/dev/null 2>&1 || stop "git commit failed"
  echo "committed on $branch: $(git -C "$proj" rev-parse --short HEAD) ($nfiles files)"
}
do_pr() {
  git -C "$proj" remote get-url origin >/dev/null 2>&1 || stop "no remote 'origin': add one, then rerun (the commit is kept on $branch)"
  command -v gh >/dev/null 2>&1 || stop "gh is not installed (the branch is committed locally on $branch)"
  gh auth status >/dev/null 2>&1 || stop "gh is not logged in: run 'gh auth login' (the branch is committed locally on $branch)"
  b=$(git -C "$proj" symbolic-ref --short -q HEAD); case "$b" in "$base"|main|master) stop "refusing to push the base branch ($b)";; esac
  git -C "$proj" push -u origin "$b" 2>&1 | tail -2 || stop "push failed (a non-fast-forward is never forced; resolve it, then rerun)"
  bf="$crew/REPORT.md"; [ -s "$bf" ] || { bf="$crew/pr-body.md"; { echo "## Objective"; sed -n '1,25p' "$crew/PLAN.md" 2>/dev/null; echo; echo "QA verdict: ${verdict:-n/a}"; } > "$bf"; }
  url=$(gh pr create --base "$base" --head "$b" --title "$title" --body-file "$bf" $draft 2>&1 | tail -1) || stop "gh pr create failed: $url"
  echo "SHIP OK $url"; echo "$url" > "$crew/PR_URL"
}
case "$mode" in commit) do_commit;; pr) do_pr;; all) do_commit; do_pr;; esac
