#!/usr/bin/env bash
# Safety net for a crew run.
#   bash crew-guard.sh <project> lock [--force]   one crew per project; stale after 2h
#   bash crew-guard.sh <project> unlock
#   bash crew-guard.sh <project> baseline "<cmd>" run the project's test/build command now, remember its result
#   bash crew-guard.sh <project> regress          rerun it, show exit change and new output lines
#   bash crew-guard.sh <project> snapshot         tar the project (aborts over 2GB); also the reference for `check`
#   bash crew-guard.sh <project> check            scope violations (exit 1 if any)
#   bash crew-guard.sh <project> restore <path>   put one file back as snapshotted (delete it if new)
# Scopes: .devin-crew/scopes.txt, lines "<lane><TAB><glob relative to project>"; .devin-crew/* always allowed.
# `check` has two modes: if any lane has a worktree (lanes/<lane>.workdir) each worktree is checked against its
# own lane's scope; otherwise the shared tree is compared with the snapshot against all scopes.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
cmd=$2; shift 2
crew="$proj/.devin-crew"; mkdir -p "$crew"
cd "$proj" || exit 2

# ponytail: skips VCS/build/dependency dirs; add more with CREW_PRUNE="dir1 dir2"
prune=(node_modules .git .devin-crew dist build .next target venv .venv __pycache__)
read -ra extra_prune <<< "${CREW_PRUNE:-}"; prune+=(${extra_prune[@]+"${extra_prune[@]}"})
list_files() {
  local args=() d
  for d in "${prune[@]}"; do args+=(-name "$d" -o); done
  find . \( "${args[@]}" -false \) -prune -o -type f -print | sed 's|^\./||' | sort
}
# build/runtime noise that is never a scope violation (bytecode, dependency dirs, OS files)
noise='(^|/)(node_modules|\.venv|venv|__pycache__)(/|$)|\.pyc$|(^|/)\.DS_Store$'
owners_of() { # path -> lane names whose scope matches (optionally only lane $2)
  local p=$1 only=${2:-} lane glob out=""
  while IFS=$'\t' read -r lane glob; do
    [ -n "$only" ] && [ "$lane" != "$only" ] && continue
    # shellcheck disable=SC2254
    case "$p" in $glob) out="$out $lane" ;; esac
  done < "$crew/scopes.txt"
  echo $out
}

case "$cmd" in
  scopes)   # two lanes owning the same or nested paths is a planning mistake: it surfaces as a merge conflict later
    [ -f "$crew/scopes.txt" ] || { echo "no scopes.txt" >&2; exit 2; }
    n=0; entries=()
    while IFS=$'\t' read -r lane glob; do [ -n "$lane" ] && entries+=("$lane	$glob"); done < "$crew/scopes.txt"
    i=0; for a in ${entries[@]+"${entries[@]}"}; do
      la=${a%%	*}; ga=${a#*	}; j=0
      for b in ${entries[@]+"${entries[@]}"}; do
        j=$((j + 1)); [ "$j" -le "$((i + 1))" ] && continue
        lb=${b%%	*}; gb=${b#*	}; [ "$la" = "$lb" ] && continue
        # shellcheck disable=SC2254
        if case "$ga" in $gb) true;; *) false;; esac || case "$gb" in $ga) true;; *) false;; esac; then
          echo "SCOPE OVERLAP: $la ($ga) and $lb ($gb)"; n=$((n + 1)); fi
      done; i=$((i + 1))
    done
    [ "$n" -eq 0 ] && echo "scopes: no overlaps"
    [ "$n" -eq 0 ]
    ;;
  lock)
    if [ -f "$crew/LOCK" ] && [ "${1:-}" != "--force" ]; then
      age=$(( $(date +%s) - $(head -1 "$crew/LOCK") ))
      if [ "$age" -lt 7200 ]; then echo "another crew holds this project (lock is ${age}s old). Use --force to take over." >&2; exit 1; fi
    fi
    date +%s > "$crew/LOCK"; echo "locked"
    ;;
  unlock) rm -f "$crew/LOCK"; echo "unlocked" ;;
  baseline)
    c=$1; echo "$c" > "$crew/baseline.cmd"
    bash -c "$c" > "$crew/baseline.out" 2>&1; echo $? > "$crew/baseline.exit"
    echo "baseline: exit $(cat "$crew/baseline.exit"), $(wc -l < "$crew/baseline.out" | tr -d ' ') lines of output (cmd: $c)"
    ;;
  regress)
    [ -f "$crew/baseline.cmd" ] || { echo "no baseline" >&2; exit 2; }
    bash -c "$(cat "$crew/baseline.cmd")" > "$crew/now.out" 2>&1; now=$?
    before=$(cat "$crew/baseline.exit")
    echo "exit before=$before now=$now"
    # lines present now but not in baseline, timing numbers stripped
    norm() { sed -E 's/[0-9]+(\.[0-9]+)?(ms|s| seconds?)//g' "$1" | sort -u; }
    new=$(comm -13 <(norm "$crew/baseline.out") <(norm "$crew/now.out") | head -40)
    [ -n "$new" ] && { echo "NEW OUTPUT LINES:"; echo "$new"; }
    [ "$now" -gt "$before" ] && exit 1
    exit 0
    ;;
  snapshot)
    list_files > "$crew/snapshot.files"
    size=$(tr '\n' '\0' < "$crew/snapshot.files" | xargs -0 ls -l 2>/dev/null | awk '{s+=$5} END{print s+0}')
    if [ "$size" -gt 2147483648 ]; then echo "refusing: $size bytes to snapshot (>2GB). Set CREW_PRUNE or narrow the project." >&2; exit 1; fi
    tr '\n' '\0' < "$crew/snapshot.files" | tar -czf "$crew/snapshot.tgz" --null -T -
    touch "$crew/snapshot.stamp"
    echo "snapshot: $(wc -l < "$crew/snapshot.files" | tr -d ' ') files, $size bytes -> $crew/snapshot.tgz"
    ;;
  check)
    [ -f "$crew/scopes.txt" ] || { echo "no scopes.txt" >&2; exit 2; }
    bad=0
    if ls "$crew"/lanes/*.workdir >/dev/null 2>&1; then
      for wf in "$crew"/lanes/*.workdir; do
        lane=$(basename "$wf" .workdir); wt=$(cat "$wf")
        [ -d "$wt" ] || continue
        git -C "$wt" status --porcelain --untracked-files=all | sed -E 's/^.{3}//; s/.* -> //' \
          | grep -vE "$noise" | while read -r path; do
            o=$(owners_of "$path")
            [ -z "$(owners_of "$path" "$lane")" ] && echo "OUTSIDE SCOPE (lane $lane): $path"
            [ "$(echo $o | wc -w | tr -d ' ')" -gt 1 ] && echo "OVERLAP (lane $lane): $path is owned by: $o"
          done > "$crew/check.$lane.tmp"
        if [ -s "$crew/check.$lane.tmp" ]; then cat "$crew/check.$lane.tmp"; bad=1; fi
        rm -f "$crew/check.$lane.tmp"
      done
      echo "worktree check: $([ $bad -eq 0 ] && echo all lanes in scope || echo VIOLATIONS)"
      exit $bad
    fi
    [ -f "$crew/snapshot.stamp" ] || { echo "no snapshot yet" >&2; exit 2; }
    list_files > "$crew/now.files"
    {
      comm -13 "$crew/snapshot.files" "$crew/now.files" | sed 's|$|\tnew|'
      comm -23 "$crew/snapshot.files" "$crew/now.files" | sed 's|$|\tdeleted|'
      find . \( -name node_modules -o -name .git -o -name .devin-crew -o -name dist -o -name build -o -name .next -o -name target -o -name venv -o -name .venv -o -name __pycache__ \) -prune -o -type f -newer "$crew/snapshot.stamp" -print \
        | sed 's|^\./||' | sort | comm -12 - "$crew/snapshot.files" | sed 's|$|\tchanged|'
    } | sort -u > "$crew/changes.tsv"
    while IFS=$'\t' read -r path kind; do
      o=$(owners_of "$path"); n=$(echo $o | wc -w | tr -d ' ')
      if [ "$n" -eq 0 ]; then echo "OUTSIDE SCOPE: $path ($kind)"; bad=1
      elif [ "$n" -gt 1 ]; then echo "OVERLAP: $path ($kind) owned by: $o"; bad=1; fi
    done < "$crew/changes.tsv"
    echo "changes since snapshot: $(wc -l < "$crew/changes.tsv" | tr -d ' ') ($([ $bad -eq 0 ] && echo all in scope || echo VIOLATIONS)). Shared-tree mode cannot say WHICH lane did it; worktree mode can."
    exit $bad
    ;;
  restore)
    p=$1
    if grep -qxF -- "$p" "$crew/snapshot.files"; then tar -xzf "$crew/snapshot.tgz" -- "$p" && echo "restored $p"
    else rm -f -- "$p" && echo "removed $p (did not exist at snapshot)"; fi
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
