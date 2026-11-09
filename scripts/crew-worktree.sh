#!/usr/bin/env bash
# Git worktree isolation: one detached worktree per lane, no commits, no extra branches.
#   bash crew-worktree.sh <project> add <lane>      create .devin-crew/wt/<lane> from HEAD, point the lane at it
#   bash crew-worktree.sh <project> merge <lane>    apply the lane's changes to the main tree as uncommitted edits
#   bash crew-worktree.sh <project> remove <lane>   delete the worktree (after merge)
# <project> must be a git repo root. Run `add` for every lane before launching any.
# ponytail: node_modules/.venv/venv at repo root are symlinked into each worktree so tests can run.
set -u
proj=$(cd "$1" && pwd) || exit 2
cmd=$2; lane=${3:-}
crew="$proj/.devin-crew"; wt="$crew/wt/$lane"
top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null) || { echo "not a git repo: $proj" >&2; exit 1; }
[ "$top" = "$proj" ] || { echo "project must be the git repo root ($top)" >&2; exit 1; }
links="node_modules .venv venv"

case "$cmd" in
  add)
    mkdir -p "$crew/wt" "$crew/lanes"
    grep -qxF '.devin-crew/' "$proj/.git/info/exclude" 2>/dev/null || echo '.devin-crew/' >> "$proj/.git/info/exclude"
    dirty=$(git -C "$proj" status --porcelain | wc -l | tr -d ' ')
    git -C "$proj" worktree add -q --detach "$wt" HEAD || exit 1
    if [ "$dirty" -gt 0 ]; then
      # Later waves must see earlier waves' merged (uncommitted) work: copy the main tree's current state into the
      # worktree and commit it there as a throwaway base (detached, never on a branch), so the lane's diff is lane-only.
      ( cd "$proj" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
          | tar -cf - --null -T - ) | tar -xf - -C "$wt"
      ( cd "$proj" && git ls-files -d -z ) | while IFS= read -r -d '' f; do rm -f "$wt/$f"; done
      git -C "$wt" add -A -- . && git -C "$wt" -c user.name=crew -c user.email=crew@local commit -q --no-verify -m "crew base"
    fi
    for l in $links; do [ -e "$proj/$l" ] && ln -s "$proj/$l" "$wt/$l"; done
    echo "$wt" > "$crew/lanes/$lane.workdir"
    echo "worktree: $wt"
    ;;
  merge)
    [ -d "$wt" ] || { echo "no worktree for $lane" >&2; exit 1; }
    excl=(); for l in $links; do excl+=(":!$l"); done
    git -C "$wt" add -N -- . "${excl[@]}" 2>/dev/null
    patch="$crew/lanes/$lane.patch"
    # Only the lane's own scope globs (scopes.txt) are merged; anything else it touched is reported and left behind.
    globs=(); while IFS=$'\t' read -r l g; do [ "$l" = "$lane" ] && globs+=("$g"); done < "$crew/scopes.txt"
    [ ${#globs[@]} -gt 0 ] || { echo "$lane has no scope in scopes.txt; refusing to merge" >&2; exit 1; }
    skipped=$(comm -23 <(git -C "$wt" diff HEAD --name-only -- . "${excl[@]}" | sort) <(git -C "$wt" diff HEAD --name-only -- "${globs[@]}" | sort))
    [ -n "$skipped" ] && { echo "$lane: NOT merged (outside its scope):"; echo "$skipped" | sed 's/^/  /'; }
    git -C "$wt" diff HEAD --binary -- "${globs[@]}" > "$patch"
    if [ ! -s "$patch" ]; then echo "$lane: no changes"; exit 0; fi
    if git -C "$proj" apply --check "$patch" 2>/tmp/crew-apply.err; then
      git -C "$proj" apply "$patch" && echo "$lane: merged ($(grep -c '^diff --git' "$patch") files), uncommitted"
    else
      echo "$lane: CONFLICT, nothing applied:"; cat /tmp/crew-apply.err; exit 1
    fi
    ;;
  remove)
    git -C "$proj" worktree remove --force "$wt" && rm -f "$crew/lanes/$lane.workdir" && echo "removed $wt"
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
