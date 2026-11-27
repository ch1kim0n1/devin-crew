#!/usr/bin/env bash
# First-milestone setup in ONE call (was 6-8 brain calls): preflight, lock, scope check, baseline, isolation. Output is a few lines.
#   bash crew-init.sh <project> "<baseline test/build command>" [--trust]
# Needs .devin-crew/scopes.txt (lane<TAB>glob) already written. Stops at the first FAIL and says why. Changes nothing outside .devin-crew/
# except worktree metadata in the repo's .git (git repo root) or a tar snapshot (otherwise).
set -u
proj=$(cd "$1" && pwd -P) || exit 2
base=${2:-}; trust=""; [ "${3:-}" = "--trust" ] && trust="--trust"
here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"
[ -f "$crew/scopes.txt" ] || { echo "INIT STOP: write $crew/scopes.txt first (lane<TAB>glob per line)"; exit 1; }
d=$(bash "$here/crew-doctor.sh" "$proj" $trust 2>&1); rc=$?
printf '%s\n' "$d" | grep -E '^(FAIL|WARN)' | head -8
[ "$rc" -ne 0 ] && { echo "INIT STOP: preflight failed (fixes above). Tell the user; nothing was started."; exit 1; }
l=$(bash "$here/crew-guard.sh" "$proj" lock 2>&1); [ $? -ne 0 ] && { echo "INIT STOP: $(printf '%s' "$l" | head -2 | tr '\n' ' ')"; exit 1; }
trap 'bash "$here/crew-guard.sh" "$proj" unlock >/dev/null' EXIT
ov=$(bash "$here/crew-guard.sh" "$proj" scopes 2>&1 | grep -E 'OVERLAP' | head -5)
[ -n "$ov" ] && { printf '%s\n' "$ov"; echo "INIT STOP: scope overlap is a planning mistake: fix scopes.txt, then rerun"; exit 1; }
if [ -n "$base" ]; then
  if ! bash "$here/crew-guard.sh" "$proj" baseline "$base" || [ "$(cat "$crew/baseline.exit" 2>/dev/null)" != 0 ]; then
    echo "INIT STOP: baseline failed. See $crew/baseline.out."
    exit 1
  fi
fi
git -C "$proj" status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.{3}//; s/.* -> //' | grep -v '^\.devin-crew/' > "$crew/prework.files"   # the user's own uncommitted work: crew-ship leaves it out unless a lane owns it
[ -s "$crew/prework.files" ] && echo "note: $(wc -l < "$crew/prework.files" | tr -d ' ') file(s) were already modified before the crew; lanes start from them, the PR leaves out the ones no lane owns"
lanes=$(awk -F'\t' 'NF>=2 && $1!="" && $1 !~ /^#/ && $1 !~ /-rev$/ {print $1}' "$crew/scopes.txt" | sort -u)
if [ "$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" = "$proj" ]; then
  touch "$crew/worktree-required" || exit 1
  for ln in $lanes; do
    wt="$crew/wt/$ln"
    if [ "$(cat "$crew/lanes/$ln.workdir" 2>/dev/null)" = "$wt" ] &&
       [ "$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" = "$wt" ]; then
      continue
    fi
    if ! output=$(bash "$here/crew-worktree.sh" "$proj" add "$ln" 2>&1); then
      echo "INIT STOP: could not prepare worktree for $ln."
      printf '%s\n' "$output" | head -3
      exit 1
    fi
    echo "worktree: $ln"
  done
else
  if ! bash "$here/crew-guard.sh" "$proj" snapshot; then
    echo "INIT STOP: could not snapshot the shared project."
    exit 1
  fi
  rm -f "$crew/worktree-required" || exit 1
fi
trap - EXIT
echo "INIT OK: lanes: $(echo $lanes). Next: write one brief per task in $crew/prompts/, then crew-conduct.sh in the background."
