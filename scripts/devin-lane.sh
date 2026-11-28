#!/usr/bin/env bash
# Run (or resume) one Devin "lane" headless. Run me with Bash run_in_background=true.
# usage: bash devin-lane.sh [--print] <project_dir> <lane> <model|-> <task_file|-> [permission_mode=dangerous]
#   --print        dry run: show the exact prompt, rights and command this launch would use; starts nothing, changes nothing
#   model "-"      reuse the model this lane was first launched with (see CREW_MODEL / MODEL file; default swe-2-flash-high)
#   task_file "-"  wake-up: the lane only gets "you have new mail"
# env: CREW_ROLE=<name>        first launch only: append templates/roles/<name>.md to the preamble
#      CREW_GIT=commit|push    first launch only, ONLY when the user told the orchestrator to: lane may commit (push needs
#                              CREW_GIT_TARGET="<remote> <branch>"). Shared-tree mode only; default none.
#      CREW_MAX_SECS=2700      wall-clock cap per turn, nudges included (status failed(timeout))
#      CREW_STALL_RETRIES=2    automatic kill+nudge attempts when the lane stalls (see crew-observe.sh)
#      CREW_BUILD_CACHE=0      do not set RUSTC_WRAPPER=sccache for a Rust project (done when sccache is installed and no wrapper is set)
#      CREW_LANE_UI=tmux|terminal|iterm   run the lane as a visible interactive session (`devin --prompt-file`) in a tmux window or a
#                              new Terminal / iTerm window (macOS) instead of headless `devin -p`: the user can read along and type.
#                              The turn ends when the lane posts its DONE line (the session is closed CREW_UI_GRACE=30 s later) or the
#                              session exits. Lost with it: the stall watchdog and nudges, the log (output stays in the window),
#                              --export, and so most error classification. The wall-clock cap still applies (raise CREW_MAX_SECS).
# First call for a lane starts a new Devin session; later calls resume it, unread mail prepended.
# A lane with .devin-crew/lanes/<lane>.workdir (see crew-worktree.sh) runs inside that git worktree.
# dangerous = Devin's bypass mode (auto-approves all tools), the user's chosen default for every lane.
set -u
dry=0; if [ "${1:-}" = "--print" ]; then dry=1; shift; fi
proj=$(cd "$1" && pwd -P) || exit 2
lane=$2; model=$3; task=$4; perm=${5:-dangerous}
ui=${CREW_LANE_UI:-}
case "$ui" in
  ""|headless) ui="";;
  tmux) command -v tmux >/dev/null 2>&1 || { echo "CREW_LANE_UI=tmux but tmux is not installed" >&2; exit 2; };;
  terminal|iterm) command -v osascript >/dev/null 2>&1 || { echo "CREW_LANE_UI=$ui needs macOS (osascript); use tmux elsewhere" >&2; exit 2; };;
  *) echo "unknown CREW_LANE_UI '$ui' (tmux, terminal, iterm or headless)" >&2; exit 2;;
esac
crew="$proj/.devin-crew"
[ "$dry" -eq 1 ] || mkdir -p "$crew/lanes" "$crew/logs"
sid_file="$crew/lanes/$lane.sid"; model_file="$crew/lanes/$lane.model"
skill_dir=$(cd "$(dirname "$0")/.." && pwd)
msg="$skill_dir/scripts/lane-msg.sh"; obs="$skill_dir/scripts/crew-observe.sh"
workdir="$proj"; workdir_file="$crew/lanes/$lane.workdir"
if [ -f "$workdir_file" ]; then
  workdir=$(cat "$workdir_file")
  if [ -z "$workdir" ] || ! resolved_workdir=$(cd "$workdir" 2>/dev/null && pwd -P); then
    echo "lane $lane work directory is unavailable: $workdir" >&2
    exit 2
  fi
  workdir=$resolved_workdir
fi
if { [ -f "$crew/worktree-required" ] || { [ -d "$crew/wt" ] && [ ! -f "$crew/snapshot.stamp" ]; }; } &&
   [ ! -f "$crew/lanes/$lane.readonly" ] &&
   { [ "$workdir" = "$proj" ] || [ ! -f "$workdir/.git" ] ||
     [ "$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null)" != "$workdir" ]; }; then
  echo "lane $lane requires a Git worktree. Prepare it before launching." >&2
  exit 2
fi
ev() { [ "$dry" -eq 1 ] || echo "$(date '+%F %T') $lane $*" >> "$crew/events.log"; }

# Lane-minutes budget (crew-budget.sh): refuse to start once exceeded, unless the user said to go on.
if b=$(bash "$skill_dir/scripts/crew-budget.sh" "$proj" check); then :; else
  brc=$?
  if [ "$brc" -eq 2 ] && [ "${CREW_BUDGET_OVERRIDE:-0}" != 1 ] && [ "$dry" -eq 1 ]; then
    echo "WOULD REFUSE (budget): $b" >&2
  elif [ "$brc" -eq 2 ] && [ "${CREW_BUDGET_OVERRIDE:-0}" != 1 ]; then
    echo "$b" >&2; echo "$(date '+%F %T') $lane BUDGET exceeded: launch refused" >> "$crew/events.log"; exit 4
  fi
  echo "$b" >&2
fi
# A Devin error that stops the lane (limit, login, trust, crash...) is the USER's to see: no relaunch until they say retry.
nu="$crew/lanes/$lane.needs-user"
if [ -f "$nu" ]; then
  if [ "${CREW_RETRY_OK:-0}" = 1 ]; then
    [ "$dry" -eq 1 ] || { ev "RETRY approved by the user after $(head -1 "$nu")"; rm -f "$nu"; }
  elif [ "$dry" -eq 1 ]; then echo "WOULD REFUSE (awaiting user after Devin error $(head -1 "$nu"))" >&2
  else
    echo "lane $lane stopped on a Devin error ($(head -1 "$nu")) and waits for the user. Report it to them; relaunch with CREW_RETRY_OK=1 only after they say retry." >&2
    ev "launch refused: awaiting user decision after $(head -1 "$nu")"; exit 5
  fi
fi
# One model for every lane: CREW_MODEL, else the first line of <skill>/MODEL, else swe-2-flash-high (free). Anything else asked for is coerced.
want=${CREW_MODEL:-$(head -1 "$skill_dir/MODEL" 2>/dev/null)}; want=${want:-swe-2-flash-high}
# Per role (optional, the user's word only): CREW_MODEL_<ROLE> (e.g. CREW_MODEL_QA, CREW_MODEL_ARCHITECT) or a one-line file MODEL.<role> next to this skill.
if [ -n "${CREW_ROLE:-}" ]; then
  rv="CREW_MODEL_$(printf '%s' "$CREW_ROLE" | tr '[:lower:]-' '[:upper:]_')"; rm_=${!rv:-$(head -1 "$skill_dir/MODEL.$CREW_ROLE" 2>/dev/null)}
  [ -n "$rm_" ] && want=$rm_
fi
if [ "$model" = "-" ]; then model=$(cat "$model_file" 2>/dev/null) || model=$want; fi
if [ "$model" != "$want" ] && ! { [ -f "$sid_file" ] && [ "$model" = "$(cat "$model_file" 2>/dev/null)" ]; }; then
  echo "model '$model' not allowed, using $want" >&2; model=$want
fi
[ "$dry" -eq 1 ] || echo "$model" > "$model_file"

n=0; for f in "$crew/logs/$lane".[0-9]*.log; do [ -e "$f" ] && n=$((n + 1)); done
log="$crew/logs/$lane.$((n + 1)).log"

body=""; [ "$task" != "-" ] && body=$(cat "$task")
if [ -f "$sid_file" ]; then
  resume=(-r "$(cat "$sid_file")"); mode="resume of session $(cat "$sid_file")"; gitmode="(unchanged: a resumed lane keeps the rights it was launched with)"
  if [ "$dry" -eq 1 ]; then   # peek only: reading would advance the lane's mail cursor
    un=$(bash "$msg" "$proj" pending | awk -v l="$lane" '$1==l{print $3}'); mail="[dry run: ${un:-0} unread message(s) would be inserted here]"
  else mail=$(bash "$msg" "$proj" read "$lane"); fi
  [ "$task" = "-" ] && body="You were woken because you have new mail. Handle every message, finish any work it implies, then append an updated DONE line to $crew/BOARD.md in exactly the format from your instructions (DONE <lane>: files changed: ... | verified: ... | contracts: v<N, the CONTRACTS.md version you last read> | open issues for other lanes: ...) and reply with the same summary."
  prompt=$(printf 'NEW MAIL (from other lanes):\n%s\n\n%s' "$mail" "$body")
  ev "resume session $(cat "$sid_file")"
else
  resume=(); mode="NEW session"
  [ "$task" = "-" ] && { echo "first launch needs a task file" >&2; exit 2; }
  t=$(cat "$skill_dir/templates/preamble.md")
  t=${t//\{\{LANE\}\}/$lane}; t=${t//\{\{PROJECT\}\}/$proj}; t=${t//\{\{WORKDIR\}\}/$workdir}
  t=${t//\{\{CREW\}\}/$crew}; t=${t//\{\{SKILLDIR\}\}/$skill_dir}
  # Git rights are opt-in, granted only when the user told the orchestrator to (CREW_GIT=commit|push, first launch only).
  gitmode=${CREW_GIT:-none}; target=${CREW_GIT_TARGET:-}
  if [ "$gitmode" != none ] && ! git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    echo "CREW_GIT ignored: $proj is not a git repo" >&2; gitmode=none; fi
  if [ "$gitmode" != none ] && [ "$workdir" != "$proj" ]; then
    echo "CREW_GIT ignored: lane runs in a worktree (its commits would hide its changes from merge and never reach the repo); the orchestrator commits after merge" >&2; gitmode=none; fi
  if [ "$gitmode" = push ] && ! printf '%s' "$target" | grep -Eq '^[A-Za-z0-9._/-]+ [A-Za-z0-9._/-]+$'; then
    echo "CREW_GIT=push needs CREW_GIT_TARGET=\"<remote> <branch>\"; falling back to commit only" >&2; gitmode=commit; fi
  case "$gitmode" in
    commit|push)
      g="You MAY commit your own work, nothing else. Stage explicit paths inside your owned scope (git add -- <paths>; never git add -A or git add .), commit with a message starting [crew:$lane], and only after your verify command passes. Commit at each finished, verified unit of work (a feature, a file group, a fix), not one big commit at the end and not every few lines. Another lane may hold .git/index.lock: wait 5 seconds and retry up to 6 times, never delete it. Never amend, rebase, reset, stash, checkout or force anything."
      if [ "$gitmode" = push ]; then
        g="$g After your last commit push once with: git push $target. If rejected as non-fast-forward, run git pull --rebase $target once, rerun your verify command, and push again; on any conflict or a second rejection stop and post BLOCKED. Never force-push and never push to any other remote or branch."
      else g="$g Do not push."; fi;;
    *) g="you may not run any git write command (no commit, push, pull, add). The orchestrator handles version control." ;;
  esac
  ev "git rights: $gitmode${target:+ ($target)}"
  t=${t//\{\{GIT\}\}/$g}
  role=""; [ -n "${CREW_ROLE:-}" ] && [ -f "$skill_dir/templates/roles/$CREW_ROLE.md" ] && role=$(cat "$skill_dir/templates/roles/$CREW_ROLE.md")
  prompt=$(printf '%s\n\n%s\n\n%s' "$t" "$role" "$body")
  ev "launch ${CREW_ROLE:-no-role} in $workdir"
fi

if [ "$dry" -eq 1 ]; then
  echo "=== DRY RUN: nothing launched, nothing changed ==="
  echo "lane: $lane | $mode | model: $model | permission mode: $perm | role: ${CREW_ROLE:-none} | git rights: $gitmode${target:+ ($target)}"
  echo "runs in: $workdir | wall-clock cap per turn: ${CREW_MAX_SECS:-2700}s | stall retries: ${CREW_STALL_RETRIES:-2}"
  if [ -n "$ui" ]; then echo "command (in a new $ui window): devin --prompt-file <prompt below> --model $model --permission-mode $perm ${resume[*]:-}"
  else echo "command: devin -p <prompt below> --model $model --permission-mode $perm --export $crew/lanes/$lane.export.json ${resume[*]:-}"; fi
  echo "=== PROMPT (exactly what the lane receives) ==="
  printf '%s\n' "$prompt"
  exit 0
fi
echo $$ > "$crew/lanes/$lane.pid"; date +%s > "$crew/lanes/$lane.started"
[ -n "$ui" ] || rm -f "$crew/lanes/$lane.ui.sh"
echo running > "$crew/lanes/$lane.status"
# Only the task this brief belongs to changes state (a lane can own several tasks; the others have not run). A brief that is
# not a task id (a fix or review brief) only revives tasks that already ran: failed or in review, never open ones.
# The task is named by the brief (prompts/<task-id>.md); a brief with another name still counts when the lane owns exactly one task.
tid=""; if [ "$task" != "-" ]; then
  tid=$(awk -F'|' -v b="$(basename "$task" .md)" -v l="$lane" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x}
    NF>=7 && t($2)!="id" && t($2)!~/^-/ { if (t($2)==b) hit=t($2); if (t($3)==l) { n++; own=t($2) } }
    END { if (hit!="") print hit; else if (n==1) print own }' "$crew/TASKS.md" 2>/dev/null)
fi
if [ -n "$tid" ]; then bash "$skill_dir/scripts/crew-tasks.sh" "$proj" set "$tid" running
elif [ "$task" != "-" ]; then bash "$skill_dir/scripts/crew-tasks.sh" "$proj" lane "$lane" "failed|review" running; fi
cd "$workdir" || exit 2
. "$skill_dir/scripts/crew-lib.sh"; build_cache_env "$workdir"
max=${CREW_MAX_SECS:-2700}; retries=${CREW_STALL_RETRIES:-2}; t0=$(date +%s); start=$t0
: > "$log"

# run_turn <prompt> [devin args...]: one devin -p turn with a watchdog.
# Sets: code, timedout (0/1), stall_reason ("" or "<STATE>: why"). Returns when devin exits or is killed.
run_turn() {
  local p=$1; shift
  stall_reason=""; timedout=0; start=$(date +%s)   # the wall-clock cap is per turn, so a nudge gets a fresh budget
  devin -p "$p" --model "$model" --permission-mode "$perm" --export "$crew/lanes/$lane.export.json" "$@" >>"$log" 2>&1 &
  local dpid=$!; echo "$dpid" > "$crew/lanes/$lane.devinpid"
  local next_check=$(( $(date +%s) + 90 )) now r rc tool_kills=0
  while kill -0 "$dpid" 2>/dev/null; do
    sleep 2; now=$(date +%s)
    if [ $((now - start)) -ge "$max" ]; then
      timedout=1; ev "TIMEOUT after ${max}s, killing"
      pkill -TERM -P "$dpid" 2>/dev/null; kill -TERM "$dpid" 2>/dev/null; sleep 3
      pkill -KILL -P "$dpid" 2>/dev/null; kill -KILL "$dpid" 2>/dev/null; break
    fi
    if [ "$now" -ge "$next_check" ]; then
      next_check=$((now + 30))
      r=$(bash "$obs" "$proj" "$lane" --stall); rc=$?
      if [ "$rc" -eq 4 ] && [ "$tool_kills" -lt 3 ]; then
        # a command Devin started is hung: kill that command only; Devin sees a failed tool call and carries on
        tool_kills=$((tool_kills + 1)); ev "HUNG-TOOL ($r): killing its commands (#$tool_kills)"
        for c in $(pgrep -P "$dpid" 2>/dev/null); do pkill -TERM -P "$c" 2>/dev/null; done
        next_check=$((now + 120))
      elif [ "$rc" -ne 0 ]; then
        stall_reason=$r; ev "STALL detected ($r): killing devin"
        pkill -TERM -P "$dpid" 2>/dev/null; kill -TERM "$dpid" 2>/dev/null; sleep 3
        pkill -KILL -P "$dpid" 2>/dev/null; kill -KILL "$dpid" 2>/dev/null; break
      fi
    fi
  done
  wait "$dpid" 2>/dev/null; code=$?
  rm -f "$crew/lanes/$lane.devinpid"
}

done_lines() { local n; n=$(grep -cE "^[^[]*DONE $lane( |:|\()" "$crew/BOARD.md" 2>/dev/null); echo "${n:-0}"; }   # 0 before BOARD.md exists; mail lines start with "[", skip them
kill_pid() { pkill -TERM -P "$1" 2>/dev/null; kill -TERM "$1" 2>/dev/null; sleep 2; pkill -KILL -P "$1" 2>/dev/null; kill -KILL "$1" 2>/dev/null; }
open_window() { # command line -> a new window the user can watch and type into
  case "$ui" in
    tmux)
      if [ -n "${TMUX:-}" ]; then tmux new-window -d -n "$lane" "$1"
      else   # one session "crew", a window per lane; the last try covers two lanes creating the session at once
        tmux new-window -d -t "=crew:" -n "$lane" "$1" 2>/dev/null || tmux new-session -d -s crew -n "$lane" "$1" 2>/dev/null || tmux new-window -d -t "=crew:" -n "$lane" "$1"
      fi;;
    terminal) osascript -e 'on run argv' -e 'tell application "Terminal" to do script (item 1 of argv)' -e 'end run' "$1" >/dev/null;;
    iterm) osascript -e 'on run argv' -e 'tell application "iTerm"' -e 'set w to (create window with default profile)' \
             -e 'tell current session of w to write text (item 1 of argv)' -e 'end tell' -e 'end run' "$1" >/dev/null;;
  esac
}
# run_ui <prompt> [devin args...]: one interactive turn. Sets code and timedout like run_turn.
run_ui() {
  local p=$1; shift
  local pf="$crew/lanes/$lane.prompt.md" run="$crew/lanes/$lane.ui.sh" pidf="$crew/lanes/$lane.devinpid" xf="$crew/lanes/$lane.ui.exit"
  local before now dpid="" doneat="" grace=${CREW_UI_GRACE:-30}
  stall_reason=""; timedout=0; code=1; start=$(date +%s); before=$(done_lines)
  printf '%s\n' "$p" > "$pf"; rm -f "${pidf:?}" "${xf:?}" "$crew/lanes/$lane.export.json"   # a stale export would name the wrong session
  { echo '#!/usr/bin/env bash'
    printf 'cd %q || exit 2\n' "$workdir"
    [ -z "${CREW_CACHE_ON:-}" ] || echo 'export RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0'   # a tmux window does not inherit our environment
    # the inner shell records its pid and becomes devin, which stays in the window's foreground and keeps the keyboard
    printf "bash -c 'echo \$\$ > \"\$0\"; exec \"\$@\"' %q" "$pidf"
    printf ' %q' "$(command -v devin)" --prompt-file "$pf" --model "$model" --permission-mode "$perm" "$@"
    printf '\necho $? > %q\n' "$xf"; } > "$run"
  echo "interactive lane (CREW_LANE_UI=$ui): its output is in the window, not in this log" >> "$log"
  open_window "bash $(printf '%q' "$run")" >>"$log" 2>&1 || { echo "error: could not open a $ui window" | tee -a "$log" >&2; return; }
  while [ ! -f "$xf" ]; do
    sleep 1; now=$(date +%s); dpid=$(cat "$pidf" 2>/dev/null)
    if [ -z "$dpid" ]; then
      [ $((now - start)) -lt "${CREW_UI_START_SECS:-60}" ] && continue
      echo "error: devin never started in the $ui window" | tee -a "$log" >&2; return
    fi
    kill -0 "$dpid" 2>/dev/null || { sleep 2; break; }   # window closed
    if [ -z "$doneat" ] && [ "$(done_lines)" -gt "$before" ]; then doneat=$now; ev "DONE line posted; closing the session in ${grace}s"; fi
    if [ -n "$doneat" ] && [ $((now - doneat)) -ge "$grace" ]; then kill_pid "$dpid"; break; fi
    if [ $((now - start)) -ge "$max" ]; then timedout=1; ev "TIMEOUT after ${max}s, killing"; kill_pid "$dpid"; break; fi
  done
  if [ "$(done_lines)" -gt "$before" ]; then code=0; else code=$(cat "$xf" 2>/dev/null); code=${code:-1}; fi
  rm -f "${pidf:?}"
}

if [ -n "$ui" ]; then run_ui "$prompt" ${resume[@]+"${resume[@]}"}
else run_turn "$prompt" ${resume[@]+"${resume[@]}"}; fi
attempt=0
while [ -n "$stall_reason" ] && [ "$timedout" -eq 0 ] && [ "$attempt" -lt "$retries" ]; do
  attempt=$((attempt + 1))
  sid=$(bash "$obs" "$proj" "$lane" --sid); [ -z "$sid" ] && break
  echo "$sid" > "$sid_file"
  ev "NUDGE $attempt/$retries on session $sid after: $stall_reason"
  echo "--- crew watchdog: stalled ($stall_reason); nudge $attempt/$retries ---" >> "$log"
  nudge="Your previous turn stopped producing output (diagnosis: $stall_reason). Do not start over. Look at the files you already changed, finish the remaining work of your task, run your verification, check your mail, and post your DONE line (or BLOCKED with one question). If a command hangs, run it with a timeout."
  run_turn "$nudge" -r "$sid"
done

# ponytail: session id comes from the export file, falling back to Devin's own session store
sid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["session_id"])' "$crew/lanes/$lane.export.json" 2>/dev/null)
[ -z "$sid" ] && sid=$(bash "$obs" "$proj" "$lane" --sid)
[ -n "$sid" ] && echo "$sid" > "$sid_file"
if [ "$timedout" -eq 1 ]; then st="failed(timeout)"
elif [ -n "$stall_reason" ]; then st="failed(stalled: ${stall_reason%%:*})"
elif [ "$code" -eq 0 ]; then st="done"
else st="failed($code)"; fi
# classify a failure and write .needs-user BEFORE the status becomes visible: the conductor must never see `failed` without its NEEDS-USER
if [ "$st" != "done" ]; then
  # Which failures are the user's to handle? Limits, login, trust, model, crashes, and exits with no known cause.
  # Stalls and timeouts stay with the orchestrator (nudge / split), unless the log shows a limit-type cause.
  err=$(bash "$obs" "$proj" "$lane" --error); cls=$(printf '%s\n' "$err" | head -1); user=0
  case "$st" in
    failed\(timeout\)|failed\(stalled*) case "$cls" in AUTH|RATE_OR_QUOTA|TRUST|MODEL) user=1;; esac;;
    *) case "$cls" in PERMISSION|CONTEXT_TOO_LONG) ;; "") cls="EXIT-${code:-1}"; user=1;; *) user=1;; esac;;
  esac
  if [ "$user" -eq 1 ]; then
    { echo "$cls"; echo "status: $st"; printf '%s\n' "$err" | tail -n +2; } > "$nu"
    ev "NEEDS-USER class=$cls status=$st"
    echo "NEEDS-USER lane=$lane class=$cls status=$st"
    printf '%s\n' "$err" | tail -n +2
    echo "user fix: $(bash "$obs" "$proj" "$lane" --ufix "$cls")"
    echo "ORCHESTRATOR: stop and tell the user now (what failed, the evidence, their fix). They either fix it and say retry, or say retry. Do not relaunch this lane until then; after their word run it with CREW_RETRY_OK=1."
  fi
fi
echo "$st" > "$crew/lanes/$lane.status"
if [ "$task" != "-" ]; then   # a lane that exited ok awaits verification; a failed one is failed
  if [ "$st" = "done" ]; then to=review; else to=failed; fi
  if [ -n "$tid" ]; then bash "$skill_dir/scripts/crew-tasks.sh" "$proj" set "$tid" "$to"; else bash "$skill_dir/scripts/crew-tasks.sh" "$proj" lane "$lane" running "$to"; fi
fi
rm -f "$crew/lanes/$lane.pid"
ev "exit status=$st session=${sid:-unknown} elapsed=$(( $(date +%s) - t0 )) nudges=$attempt"
echo "lane=$lane status=$st session=${sid:-unknown} log=$log"
[ "$st" = "done" ] || echo "diagnose: bash $skill_dir/scripts/crew-observe.sh $proj $lane"
rs=0; case "$mode" in resume*) rs=1;; esac
bash "$skill_dir/scripts/crew-ledger.sh" turn "$proj" "$lane" "$st" "$(( $(date +%s) - t0 ))" "$attempt" "$rs" "${cls:--}" "${sid:-}"
if [ "$st" = "done" ]; then exit 0; fi
exit "${code:-1}"
