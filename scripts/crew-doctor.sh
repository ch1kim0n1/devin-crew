#!/usr/bin/env bash
# Preflight: can a crew run here? Changes nothing (except with --trust, which runs one tiny Devin turn and deletes its own session).
#   bash crew-doctor.sh <project> [--trust]
# Prints OK / WARN / FAIL lines, each FAIL/WARN with the fix. Exit 1 if any FAIL.
set -u
proj=$(cd "${1:-.}" 2>/dev/null && pwd -P) || { echo "FAIL project folder does not exist: ${1:-.}"; exit 1; }
trust=0; [ "${2:-}" = "--trust" ] && trust=1
model=swe-2-flash-high
bad=0
ok()   { echo "OK   $*"; }
warn() { echo "WARN $*"; }
fail() { echo "FAIL $*"; bad=1; }

for t in git python3 sqlite3 tar awk pgrep; do
  if command -v "$t" >/dev/null 2>&1; then ok "tool: $t"; else fail "tool missing: $t -> install it (the scripts need it)"; fi
done

if command -v devin >/dev/null 2>&1; then
  ok "devin on PATH ($(devin version 2>/dev/null | head -1))"
  as=$(devin auth status 2>&1 | head -1)
  case "$as" in
    Logged\ in*) ok "devin auth: $as";;
    *) fail "devin not logged in ($as) -> run: devin auth login";;
  esac
  if models=$(devin models 2>&1); then
    if printf '%s' "$models" | grep -q "$model"; then ok "model available: $model"
    else fail "model $model not in 'devin models' -> lanes are fixed to it; check the account's plan"; fi
  else warn "could not list models -> network or auth problem, check: devin models"; fi
else
  fail "devin not found -> install the Devin CLI (https://devin.ai) and run: devin auth login"
fi

db="$HOME/.local/share/devin/cli/sessions.db"
if [ -r "$db" ]; then ok "session store readable (observability on)"
else warn "session store not found at $db -> crew-observe falls back to process/log/file signals only"; fi

if top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null); then
  if [ "$top" = "$proj" ]; then
    n=$(git -C "$proj" status --porcelain | wc -l | tr -d ' ')
    ok "git repo root, branch $(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null), $n uncommitted file(s) -> worktree mode available"
    [ "$n" -gt 0 ] && warn "uncommitted work exists -> lanes start from it (worktrees copy it as their base); commit or stash first if unsure"
  else warn "inside a git repo but not its root ($top) -> worktree mode needs the root; use a shared tree + snapshot, or run from the root"; fi
else warn "not a git repo -> shared tree: lanes edit in place, only the snapshot protects you"; fi

kb=$(du -sk "$proj" 2>/dev/null | awk '{print $1}')
[ "${kb:-0}" -gt 2000000 ] && warn "project is over 2GB -> the snapshot refuses it; rely on git/worktrees or set CREW_PRUNE for build dirs"
free=$(df -k "$proj" 2>/dev/null | awk 'NR==2{print $4}')
[ "${free:-9999999}" -lt 1000000 ] && warn "under 1GB free disk -> worktrees and snapshots may fail"

crew="$proj/.devin-crew"
if [ -d "$crew" ]; then
  [ -f "$crew/LOCK" ] && warn "a crew lock is held (.devin-crew/LOCK) -> another crew may be running here; check crew-status.sh, or unlock if it is stale"
  run=0; for f in "$crew"/lanes/*.status; do [ -e "$f" ] && [ "$(cat "$f")" = running ] && run=$((run + 1)); done
  [ "$run" -gt 0 ] && warn "$run lane(s) marked running -> resume or inspect them (crew-resume.sh), do not start duplicates"
  [ -f "$crew/PLAN.md" ] && ok "found an existing plan (.devin-crew/PLAN.md) -> /devin-crew resume can continue it"
fi

if [ "$trust" -eq 1 ] && command -v devin >/dev/null 2>&1; then
  ids() { (cd "$proj" && devin list --format json 2>/dev/null) | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
d=d if isinstance(d,list) else d.get("sessions",[])
print("\n".join(str(x.get("id","")) for x in d))' 2>/dev/null; }
  before=$(ids)
  out=$(cd "$proj" && devin -p "Reply OK, no tools" --permission-mode dangerous 2>&1 | head -5)
  if printf '%s' "$out" | grep -qi "untrusted"; then fail "workspace not trusted -> run 'devin' once in $proj and accept the trust prompt (never bypassed by this skill)"
  elif printf '%s' "$out" | grep -q OK; then ok "workspace trusted, devin answered"
  else fail "trust check got no OK: $(printf '%s' "$out" | head -1 | cut -c1-120)"; fi
  # delete only the session this check created
  for id in $(ids); do printf '%s\n' "$before" | grep -qx "$id" || devin rm "$id" --force >/dev/null 2>&1; done
else
  [ "$trust" -eq 0 ] && echo "note: run with --trust to also test workspace trust (one tiny Devin turn)"
fi

echo "doctor: $([ "$bad" -eq 0 ] && echo "ready" || echo "NOT READY")"
exit "$bad"
