#!/usr/bin/env bash
# One-call post-exit digest of a lane: acceptance, scope, contract, size of the change, DONE line, verdict.
# Replaces the observe + verify + guard + git diff + board read sequence (the brain reads ~15 lines, never a raw diff).
#   bash crew-collect.sh <project> <lane> [--merge]
# Verdict (last line) and exit code:  CLEAN 0 | FIX 1 (a lane can fix it from the printed failures) | BRAIN 2 (needs judgment) | WAIT 3 (still running)
# --merge: when CLEAN and the lane has a worktree, also run crew-worktree.sh merge; a conflict makes the verdict BRAIN.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
lane=${2:?lane}; merge=0; [ "${3:-}" = "--merge" ] && merge=1
here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"
st=$(cat "$crew/lanes/$lane.status" 2>/dev/null || echo none)
case "$st" in running|waking) echo "COLLECT $lane: still $st"; echo "VERDICT WAIT"; exit 3;; none) echo "COLLECT $lane: never started"; echo "VERDICT BRAIN (never started)"; exit 2;; esac
echo "COLLECT $lane status=$st"
verdict=CLEAN; why=""
bump() { # severity order CLEAN < FIX < BRAIN
  case "$1:$verdict" in FIX:CLEAN) verdict=FIX;; BRAIN:*) verdict=BRAIN;; esac; why="${why:+$why; }$2"; }

if [ -f "$crew/lanes/$lane.needs-user" ]; then echo "  NEEDS-USER: $(head -1 "$crew/lanes/$lane.needs-user")"; bump BRAIN "Devin error, the user decides"; fi
case "$st" in done) ;; *) bump BRAIN "lane $st (run crew-observe.sh $proj $lane)";; esac

# acceptance + contract freshness (only for a lane that exited ok; a failed lane has nothing to verify yet)
if [ "$st" = "done" ]; then
  v=$(bash "$here/crew-verify.sh" "$proj" "$lane" 2>&1)
  printf '%s\n' "$v" | grep -E '^(PASS|FAIL|TIMEOUT|SKIP|CONTRACT-|STALE-CONTRACT|NO-CONTRACT)|^    ' | head -24 | sed 's/^/  /'
  printf '%s\n' "$v" | grep -qE '^(FAIL|TIMEOUT)' && bump FIX "acceptance failed"
  printf '%s\n' "$v" | grep -q '^STALE-CONTRACT' && bump FIX "built against an old contract"
  printf '%s\n' "$v" | grep -q '^NO-CONTRACT-VERSION' && bump FIX "DONE line lacks 'contracts: vN'"
  grep -qE "DONE $lane( |:|\()" "$crew/BOARD.md" 2>/dev/null || bump FIX "no DONE line on BOARD.md"
fi

# scope (guard reads each worktree against its own lane; shared tree cannot say which lane)
if [ -f "$crew/scopes.txt" ]; then
  g=$(bash "$here/crew-guard.sh" "$proj" check 2>&1); grc=$?
  mine=$(printf '%s\n' "$g" | grep -E "OUTSIDE SCOPE|OVERLAP" | grep -E "lane $lane\)|^OUTSIDE SCOPE: |^OVERLAP: " | head -6)
  if [ -n "$mine" ]; then printf '%s\n' "$mine" | sed 's/^/  /'; bump BRAIN "scope violation"; elif [ "$grc" -eq 2 ]; then echo "  scope: not checkable ($(printf '%s' "$g" | head -1))"; else echo "  scope: clean"; fi
fi

# size of the change, from the lane's worktree or the shared tree: counts and the biggest files only
wd="$proj"; [ -f "$crew/lanes/$lane.workdir" ] && wd=$(cat "$crew/lanes/$lane.workdir")
if [ -d "$wd" ] && git -C "$wd" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "$wd" != "$proj" ]; then git -C "$wd" add -N -- . ":(exclude,glob)**/__pycache__/**" ":(exclude,glob)**/*.pyc" ":(exclude,glob)**/.DS_Store" ":!node_modules" ":!.venv" ":!venv" 2>/dev/null; fi
  ns=$(git -C "$wd" diff HEAD --numstat 2>/dev/null | grep -v -E '__pycache__|\.pyc$')
  nf=$(printf '%s\n' "$ns" | grep -c .); add=$(printf '%s\n' "$ns" | awk '{a+=$1} END{print a+0}'); del=$(printf '%s\n' "$ns" | awk '{d+=$2} END{print d+0}')
  echo "  changed: $nf files +$add/-$del; biggest: $(printf '%s\n' "$ns" | awk 'NF>=3{print $1+$2, $3"(+"$1"/-"$2")"}' | sort -rn | head -3 | cut -d' ' -f2- | tr '\n' ' ')"
  [ "$wd" = "$proj" ] && echo "  (shared tree: counts include every lane's edits)"
fi
d=$(grep -E "DONE $lane( |:|\()" "$crew/BOARD.md" 2>/dev/null | tail -1)
[ -n "$d" ] && echo "  done-line: $(printf '%s' "$d" | cut -c1-260)"
if [ -n "$d" ] && printf '%s' "$d" | grep -qiE 'not verified|NOT run|unverified'; then echo "  note: DONE line admits something is unverified; read it before merging"; fi

if [ "$merge" -eq 1 ] && [ "$verdict" = CLEAN ] && [ -f "$crew/lanes/$lane.workdir" ]; then
  m=$(bash "$here/crew-worktree.sh" "$proj" merge "$lane" 2>&1); mrc=$?
  printf '%s\n' "$m" | head -8 | sed 's/^/  merge: /'
  [ "$mrc" -ne 0 ] && bump BRAIN "merge conflict"
  printf '%s' "$m" | grep -q 'NOT merged (outside its scope)' && bump BRAIN "files outside scope were left behind"
fi
echo "VERDICT $verdict${why:+ ($why)}"
case "$verdict" in CLEAN) exit 0;; FIX) exit 1;; *) exit 2;; esac
