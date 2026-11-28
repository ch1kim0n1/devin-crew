#!/usr/bin/env bash
# Preflight: can a crew run here? Changes nothing, except `git fetch` (remote-tracking refs only; CREW_DOCTOR_FETCH=0 skips it)
# and --trust, which runs one tiny Devin turn and deletes its own session.
#   bash crew-doctor.sh <project> [--trust]
# Prints OK / WARN / FAIL lines, each FAIL/WARN with the fix. Exit 1 if any FAIL.
set -u
proj=$(cd "${1:-.}" 2>/dev/null && pwd -P) || { echo "FAIL project folder does not exist: ${1:-.}"; exit 1; }
trust=0; [ "${2:-}" = "--trust" ] && trust=1
model=${CREW_MODEL:-$(head -1 "$(dirname "$0")/../MODEL" 2>/dev/null)}; model=${model:-swe-2-flash-high}
bad=0
. "$(cd "$(dirname "$0")" && pwd)/crew-lib.sh"
ok()   { echo "OK   $*"; }
warn() { echo "WARN $*"; }
fail() { echo "FAIL $*"; bad=1; }

for t in git python3 sqlite3 tar awk pgrep; do
  if command -v "$t" >/dev/null 2>&1; then ok "tool: $t"; else fail "tool missing: $t -> install it (the scripts need it)"; fi
done

# Sandboxed agent shells (Codex workspace-write, containers) block what devin needs: the network and its own data folder.
db="${DEVIN_SESSIONS_DB:-$HOME/.local/share/devin/cli/sessions.db}"
if [ "${CODEX_SANDBOX_NETWORK_DISABLED:-0}" = 1 ]; then
  fail "this shell has the network disabled (CODEX_SANDBOX_NETWORK_DISABLED=1) -> devin cannot reach its servers; run Codex with [sandbox_workspace_write] network_access = true, or sandbox_mode = danger-full-access (see reference/codex.md)"
fi
if [ -d "$(dirname "$db")" ] && [ ! -w "$(dirname "$db")" ]; then
  fail "cannot write Devin's data folder $(dirname "$db") (sandbox?) -> add it to the sandbox's writable roots (Codex: sandbox_workspace_write.writable_roots) or relax the sandbox (see reference/codex.md)"
fi
[ -w "$proj" ] || fail "project folder is not writable from this shell -> lanes and .devin-crew/ need write access"

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

if [ -r "$db" ]; then ok "session store readable (observability on)"
else warn "session store not found at $db -> crew-observe falls back to process/log/file signals only"; fi

if top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null); then
  if [ "$top" = "$proj" ]; then
    n=$(git -C "$proj" status --porcelain | wc -l | tr -d ' ')
    ok "git repo root, branch $(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null), $n uncommitted file(s) -> worktree mode available"
    [ "$n" -gt 0 ] && warn "uncommitted work exists -> lanes start from it (worktrees copy it as their base); commit or stash first if unsure"
    # lanes start from HEAD: commits that exist only on the remote would be missed, and all their work would conflict later
    cur=$(git -C "$proj" symbolic-ref --short -q HEAD)
    up=""; uprem=""
    [ -n "$cur" ] && { up=$(git -C "$proj" for-each-ref --format='%(upstream:short)' "refs/heads/$cur"); uprem=$(git -C "$proj" config "branch.$cur.remote"); }
    if [ "${CREW_DOCTOR_FETCH:-1}" != 0 ]; then
      for r in $(printf '%s\n' origin $uprem | sort -u); do
        git -C "$proj" remote get-url "$r" >/dev/null 2>&1 || continue
        (  # never stop for a password: an agent shell has nobody to type it
          export GIT_TERMINAL_PROMPT=0
          [ -n "${GIT_SSH_COMMAND:-}${GIT_SSH:-}$(git -C "$proj" config core.sshCommand)" ] || export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
          git -C "$proj" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet "$r" </dev/null >/dev/null 2>&1
        ) || warn "git fetch $r failed -> the behind check uses the last fetched state"
      done
    fi
    def=$(git -C "$proj" symbolic-ref --short -q refs/remotes/origin/HEAD)
    [ -n "$def" ] || for b in main master; do git -C "$proj" show-ref --verify -q "refs/remotes/origin/$b" && { def=origin/$b; break; }; done
    for ref in $(printf '%s\n' $up $def | awk '!seen[$0]++'); do
      behind=$(git -C "$proj" rev-list --count "HEAD..$ref" 2>/dev/null)
      [ "${behind:-0}" -gt 0 ] && warn "branch is $behind commit(s) behind $ref -> lanes would start from a stale base; pull or switch first"
    done
  else warn "inside a git repo but not its root ($top) -> worktree mode needs the root; use a shared tree + snapshot, or run from the root"; fi
else warn "not a git repo -> shared tree: lanes edit in place, only the snapshot protects you"; fi

kb=$(du -sk "$proj" 2>/dev/null | awk '{print $1}')
[ "${kb:-0}" -gt 2000000 ] && warn "project is over 2GB -> the snapshot refuses it; rely on git/worktrees or set CREW_PRUNE for build dirs"
free=$(df -k "$proj" 2>/dev/null | awk 'NR==2{print $4}')
[ "${free:-9999999}" -lt 1000000 ] && warn "under 1GB free disk -> worktrees and snapshots may fail"

crew="$proj/.devin-crew"
# shared services: lanes launched against a dead database all fail for a reason no code change fixes
if [ -f "$crew/services.txt" ]; then
  while IFS= read -r line; do
    case "$line" in
      "OK   "*) ok "service ${line#OK   }";;
      DOWN\ *) n=${line#DOWN }; n=${n%% *}; r=""; case "$line" in *"| restart: "*) r=${line##*| restart: };; esac
        fail "service $n is down -> start it before launching${r:+ (restart command: $r)}";;
    esac
  done < <(bash "$(cd "$(dirname "$0")" && pwd)/crew-services.sh" "$proj" check 2>/dev/null)
fi
# every worktree builds and tests on its own: on a small machine many lanes of a compiled or browser-tested stack starve each other
stack=""; for f in Cargo.toml CMakeLists.txt build.gradle build.gradle.kts pom.xml playwright.config.ts playwright.config.js; do
  [ -f "$proj/$f" ] && stack="$stack${stack:+, }$f"; done
k=$(build_lanes_hint)
[ -n "$stack" ] && [ "$k" -lt 5 ] && warn "build-heavy project ($stack) on $(machine_cores) cores, $(machine_ram_gb) GB -> plan at most $k lanes (each worktree builds and tests on its own)"
[ -f "$proj/Cargo.toml" ] && ! command -v sccache >/dev/null 2>&1 && echo "note: install sccache so lanes share Rust builds (used automatically once installed)"
# the skill itself: a stale or half-copied install silently loses the token-saving lanes (conductor, QA, reviewer)
sk="$(cd "$(dirname "$0")/.." && pwd)"; miss=""
for f in crew-conduct crew-collect crew-review crew-audit crew-init; do [ -f "$sk/scripts/$f.sh" ] || miss="$miss $f.sh"; done
[ -f "$sk/templates/roles/qa.md" ] || miss="$miss roles/qa.md"
if [ -n "$miss" ]; then warn "this skill install ($sk) is stale: missing$miss -> update it: git -C $sk pull --ff-only, or re-run install.sh (Codex: install.sh --codex replaces a copy with a link)"
elif [ ! -d "$sk/.git" ] && [ ! -L "$(dirname "$sk")/$(basename "$sk")" ]; then warn "this skill install is a plain copy (no .git, not a link): it will not update by itself -> re-run install.sh"
else ok "skill install has the conductor, collect, review, audit and init scripts"; fi

# shipping a PR needs gh; only a note, since the crew works without it
if grep -qiE '^ship: *(yes|per-task)' "$crew/PLAN.md" 2>/dev/null || [ "${CREW_SHIP_OK:-0}" = 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then warn "shipping is authorized but gh is not installed -> install it (brew install gh), the run would end without a PR"
  elif ! gh auth status >/dev/null 2>&1; then warn "shipping is authorized but gh is not logged in -> gh auth login (never done by this skill)"
  elif ! git -C "$proj" remote get-url origin >/dev/null 2>&1; then warn "shipping is authorized but the repo has no 'origin' remote -> add one"
  else ok "gh is logged in and a remote exists: the run can end with a pull request"; fi
fi
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
