#!/usr/bin/env bash
# See what a lane is really doing, and why it failed or hangs. Read-only (never writes to Devin's data).
#   bash crew-observe.sh <project> [lane]            full diagnosis of one lane (default: every lane running or failed)
#   bash crew-observe.sh <project> <lane> --stall    machine check used by the watchdog: exit 0 healthy, 3 stalled, 4 hung tool
#   bash crew-observe.sh <project> <lane> --sid      print the lane's Devin session id
#   bash crew-observe.sh <project> --timeline        .devin-crew/events.log
# Sources: Devin's sessions.db (live message + tool-call records of THIS lane's session only), the Devin process log
# (~/.local/share/devin/cli/logs/*_<pid>.log), the process tree, file mtimes in the lane's workdir, the lane's own log.
# Never reads credentials. Thresholds (seconds): CREW_EMPTY_STALL_SECS=120 CREW_MODEL_STALL_SECS=420 CREW_TOOL_STALL_SECS=1200
set -u
proj=$(cd "$1" && pwd -P) || exit 2
crew="$proj/.devin-crew"
DB=${DEVIN_SESSIONS_DB:-$HOME/.local/share/devin/cli/sessions.db}
LOGS="$(dirname "$DB")/logs"
EMPTY_STALL=${CREW_EMPTY_STALL_SECS:-120}; MODEL_STALL=${CREW_MODEL_STALL_SECS:-420}; TOOL_STALL=${CREW_TOOL_STALL_SECS:-1200}
now=$(date +%s)

q() { sqlite3 -readonly "$DB" "$1" 2>/dev/null; }
esc() { printf '%s' "${1//\'/\'\'}"; }
ago() { local s=$1; [ "$s" -lt 0 ] && s=0; if [ "$s" -ge 3600 ]; then echo "$((s/3600))h$((s%3600/60))m"; elif [ "$s" -ge 60 ]; then echo "$((s/60))m$((s%60))s"; else echo "${s}s"; fi; }
hms() { date -r "$1" '+%H:%M:%S' 2>/dev/null || date -d "@$1" '+%H:%M:%S' 2>/dev/null || echo "?"; }   # BSD, then GNU
if stat -c %Y / >/dev/null 2>&1; then mtimes() { xargs -0 stat -c %Y 2>/dev/null; }   # GNU
else mtimes() { xargs -0 stat -f %m 2>/dev/null; }; fi                                   # BSD/macOS
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }

if [ "${2:-}" = "--timeline" ]; then cat "$crew/events.log" 2>/dev/null || echo "(no events yet)"; exit 0; fi

lane_sid() { # lane -> session id (saved, else newest session in the lane's workdir)
  local lane=$1 wd sid
  sid=$(cat "$crew/lanes/$lane.sid" 2>/dev/null)
  if [ -z "$sid" ]; then
    wd=$proj; [ -f "$crew/lanes/$lane.workdir" ] && wd=$(cat "$crew/lanes/$lane.workdir")
    sid=$(q "select id from sessions where working_directory='$(esc "$wd")' order by created_at desc limit 1")
  fi
  echo "$sid"
}

classify_error() { # text file(s) -> CLASS + evidence
  local pat cls f
  for pat in \
    'AUTH|unauthori[sz]ed|[[:<:]]401[[:>:]]|not logged in|auth login|token (expired|invalid)|invalid.*credential' \
    'RATE_OR_QUOTA|[[:<:]]429[[:>:]]|rate.?limit|quota|too many requests|billing|credits? (exhausted|required)|usage limit' \
    'TRUST|untrusted workspace' \
    'PERMISSION|rejected a tool call|requires confirmation' \
    'CONTEXT_TOO_LONG|context (length|window)|maximum context|too many tokens|prompt is too long' \
    'NETWORK|connection (refused|reset|closed)|timed? ?out|dns|ENOTFOUND|certificate|network is unreachable|broken pipe' \
    'MODEL|model.*(not found|unavailable|unknown|not supported)' \
    'CRASH|panicked|panic:|segmentation|out of memory|killed'; do
    cls=${pat%%|*}; pat=${pat#*|}
    for f in "$@"; do
      [ -f "$f" ] || continue
      if grep -Eiq -- "$pat" "$f"; then echo "$cls"; grep -Ei -- "$pat" "$f" | tail -3 | cut -c1-200 | sed 's/^/    evidence: /'; return 0; fi
    done
  done
  return 1
}

ufix() { case "$1" in   # what the USER can do about it (goes into the report Claude gives them)
  AUTH) echo "log in again: devin auth login";;
  RATE_OR_QUOTA) echo "Devin usage limit or billing: wait for the limit to reset, or add credit / change plan";;
  TRUST) echo "run devin once in the project folder and accept workspace trust";;
  MODEL) echo "the lane model is unavailable: check devin models; the model is a fixed rule, so tell me if you want it changed";;
  NETWORK) echo "check the network, VPN or proxy";;
  CRASH) echo "Devin crashed or ran out of memory: free memory or update devin";;
  EXIT-*) echo "Devin exited with an error and no known cause: see the log tail";;
  *) echo "see the log tail";;
esac; }

if [ "${3:-}" = "--error" ]; then   # class line + evidence lines for the lane's newest log (empty = no known cause)
  l=$(ls -t "$crew"/logs/"${2:-x}".*.log 2>/dev/null | head -1)
  [ -n "$l" ] && classify_error "$l"
  exit 0
fi
if [ "${3:-}" = "--ufix" ]; then ufix "${4:-}"; exit 0; fi

remedy() { case "$1" in
  AUTH|RATE_OR_QUOTA|TRUST|MODEL) echo "STOP. Report to the user (what failed, the evidence, their fix: $(ufix "$1")) and ask: they fix it and say retry, or they say retry. Relaunch only with CREW_RETRY_OK=1 after their word.";;
  PERMISSION) echo "lane was not in bypass mode; relaunch with permission_mode dangerous";;
  CONTEXT_TOO_LONG) echo "start a fresh lane with a narrower task (delete the lane's .sid file first)";;
  NETWORK) echo "retry once; if it repeats, ask the user about connectivity/VPN";;
  CRASH) echo "read the process log tail below, retry once with a narrower task, then report";;
  TIMEOUT) echo "task too big for one turn: split it, relaunch with a narrower task";;
  STALLED*) echo "kill and resume with a nudge (the watchdog does this automatically)";;
  *) echo "read the lane log tail below";;
esac; }

diagnose() { # lane [mode]
  local lane=$1 mode=${2:-full}
  local status dpid acp sid wd started
  status=$(cat "$crew/lanes/$lane.status" 2>/dev/null || echo not-started)
  dpid=$(cat "$crew/lanes/$lane.devinpid" 2>/dev/null)
  started=$(cat "$crew/lanes/$lane.started" 2>/dev/null || echo "$now")
  wd=$proj; [ -f "$crew/lanes/$lane.workdir" ] && wd=$(cat "$crew/lanes/$lane.workdir")
  sid=$(lane_sid "$lane")
  local alive=0; [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null && alive=1

  # --- process tree: tool commands = descendants of devin that are not devin itself
  local tools="" tool_cpu=0 tpid
  if [ "$alive" -eq 1 ]; then
    acp=$(pgrep -P "$dpid" 2>/dev/null | head -1)
    for tpid in $(descendants "$dpid"); do
      local cmd; cmd=$(ps -o command= -p "$tpid" 2>/dev/null | cut -c1-110)
      case "$cmd" in *"devin acp"*|*"devin -p"*|"") continue ;; esac
      tools="$tools$tpid|$(ps -o etime= -p "$tpid" | tr -d ' ')|$(ps -o pcpu= -p "$tpid" | tr -d ' ')|$cmd"$'\n'
      tool_cpu=$(echo "$tool_cpu $(ps -o pcpu= -p "$tpid" | tr -d ' ')" | awk '{m=$1; if ($2>m) m=$2; print m}')
    done
  fi

  # --- session records
  local lastnode lnrole lnlen lncalls lnat toolrow lastmsg
  lastnode=$(q "select node_id||'|'||json_extract(chat_message,'\$.role')||'|'||ifnull(length(json_extract(chat_message,'\$.content')),0)||'|'||ifnull(json_array_length(json_extract(chat_message,'\$.tool_calls')),0)||'|'||created_at from message_nodes where session_id='$(esc "$sid")' order by node_id desc limit 1")
  IFS='|' read -r _ lnrole lnlen lncalls lnat <<< "$lastnode"
    toolrow=$(q "select ifnull(json_extract(tool_call_json,'\$.title'),'?')||' ['||ifnull(json_extract(tool_call_json,'\$.kind'),'?')||'] '||ifnull(json_extract(tool_call_update_json,'\$.status'),'IN-FLIGHT') from tool_call_state where session_id='$(esc "$sid")' order by rowid desc limit 1")
  lastmsg=$(q "select substr(replace(json_extract(chat_message,'\$.content'),char(10),' '),1,200) from message_nodes where session_id='$(esc "$sid")' and json_extract(chat_message,'\$.role')='assistant' and length(json_extract(chat_message,'\$.content'))>0 order by node_id desc limit 1")
  # "progress" = a tool result, or an assistant message with text or tool calls. Devin re-prompts itself with "continue"
  # after empty replies; those records must not count as activity or an empty-reply loop looks alive forever.
  local prog trail fsm=0 subst
  subst="json_extract(chat_message,'\$.role')='tool' or (json_extract(chat_message,'\$.role')='assistant' and (ifnull(length(json_extract(chat_message,'\$.content')),0)>0 or ifnull(json_array_length(json_extract(chat_message,'\$.tool_calls')),0)>0))"
  prog=$(q "select ifnull(max(created_at),0) from message_nodes where session_id='$(esc "$sid")' and ($subst)")
  trail=$(q "select count(*) from message_nodes where session_id='$(esc "$sid")' and json_extract(chat_message,'\$.role')='assistant' and ifnull(length(json_extract(chat_message,'\$.content')),0)=0 and ifnull(json_array_length(json_extract(chat_message,'\$.tool_calls')),0)=0 and node_id > (select ifnull(max(node_id),0) from message_nodes where session_id='$(esc "$sid")' and ($subst))")
  fsm=$(find "$wd" \( -name .git -o -name node_modules -o -name .devin-crew \) -prune -o -type f -print0 2>/dev/null | mtimes | sort -n | tail -1)
  local last=${prog:-0}; [ "${fsm:-0}" -gt "$last" ] && [ "${fsm:-0}" -ge "$started" ] && last=$fsm
  [ "$last" -eq 0 ] && last=$started
  local idle=$((now - last))

  # --- verdict
  local state why
  if [ "$status" = running ] && [ "$alive" -eq 0 ]; then state=CRASHED; why="status says running but the Devin process is gone"
  elif [ "$status" != running ] && [ "$status" != not-started ]; then
    case "$status" in done) state=FINISHED; why="lane exited cleanly";; *"timeout"*) state=TIMEOUT; why="killed by the wall-clock watchdog";; *) state=FAILED; why="exited with $status";; esac
  elif [ "$status" = not-started ]; then state=NOT-STARTED; why="no launch recorded"
  elif [ -n "$tools" ]; then
    if [ "$idle" -gt "$TOOL_STALL" ] && awk "BEGIN{exit !($tool_cpu < 1.0)}"; then state=STALLED-TOOL-HUNG; why="a command has run with ~0% CPU and no session activity for $(ago "$idle")"
    else state=WORKING-TOOL; why="running a command; last session activity $(ago "$idle") ago"; fi
  elif [ "${trail:-0}" -ge 1 ] && [ "$idle" -gt "$EMPTY_STALL" ]; then
    state=STALLED-EMPTY-RESPONSE; why="the model returned ${trail} empty repl$([ "$trail" = 1 ] && echo y || echo ies) in a row (no text, no tool call); last real progress $(ago "$idle") ago; Devin never exited"
  elif [ "$lnrole" = assistant ] && [ "${lnlen:-0}" -gt 0 ] && [ "${lncalls:-0}" -eq 0 ] && [ "$idle" -gt 90 ]; then
    state=STALLED-NOT-EXITING; why="the lane gave a final answer $(ago "$idle") ago but the process did not exit"
  elif [ "$lnrole" = assistant ] && [ "${lncalls:-0}" -gt 0 ] && [ "$idle" -gt "$MODEL_STALL" ]; then
    state=STALLED-TOOL-NO-PROCESS; why="a tool call was issued $(ago "$idle") ago but no command is running"
  elif { [ "$lnrole" = user ] || [ "$lnrole" = tool ]; } && [ "$idle" -gt "$MODEL_STALL" ]; then
    state=STALLED-AWAITING-MODEL; why="waiting for the model's reply for $(ago "$idle") (last record: $lnrole)"
  elif [ "$idle" -gt $((MODEL_STALL * 2)) ]; then state=STALLED-UNKNOWN; why="no activity of any kind for $(ago "$idle")"
  elif [ "$idle" -le 120 ]; then state=ACTIVE; why="activity $(ago "$idle") ago"
  else state=THINKING; why="no new records for $(ago "$idle") (within normal model latency)"; fi

  if [ "$mode" = stall ]; then
    echo "$state: $why"
    case "$state" in STALLED-TOOL-HUNG) exit 4;; STALLED*) exit 3;; *) exit 0;; esac
  fi

  # --- full report
  local plog="" f
  for f in "$LOGS"/devin_*_"${acp:-x}".log; do [ -f "$f" ] && plog=$f; done
  echo "== lane $lane   session ${sid:-unknown}   status $status   up $(ago $((now - started)))"
  echo "state:          $state"
  echo "why:            $why"
  echo "last progress:  $(hms "$last") ($(ago "$idle") ago)   [last record of any kind $(hms "${lnat:-0}"), last file change $(hms "${fsm:-0}"), empty replies since progress: ${trail:-0}]"
  echo "last tool call: ${toolrow:-none}"
  echo "last words:     ${lastmsg:-(none)}"
  if [ -n "$tools" ]; then echo "running commands (pid|elapsed|cpu%|command):"; echo "$tools" | sed '/^$/d; s/^/    /'; else echo "running commands: none"; fi
  local errs=""
  [ -n "$plog" ] && errs=$(grep -E ' (ERROR|WARN) ' "$plog" 2>/dev/null | grep -Ev 'skills_loading|message_forest' | tail -4 | cut -c1-220)
  [ -n "$errs" ] && { echo "process log warnings/errors:"; echo "$errs" | sed 's/^/    /'; }
  local lastlog flt; lastlog=$(ls -t "$crew"/logs/"$lane".*.log 2>/dev/null | head -1)
  flt=$(mktemp); [ -n "$plog" ] && grep -E ' (ERROR|WARN) ' "$plog" 2>/dev/null | grep -Ev 'skills_loading|message_forest' > "$flt"
  if [ "$state" = FAILED ] || [ "$state" = TIMEOUT ] || [ "$state" = CRASHED ] || [[ "$state" == STALLED* ]]; then
    local cls
    if [ "$state" = TIMEOUT ]; then cls=TIMEOUT; else cls=$(classify_error "$lastlog" "$flt" | head -1); fi
    if [ -n "${cls:-}" ] && [ "$cls" != "" ]; then
      echo "error class:    $cls"; [ "$state" != TIMEOUT ] && classify_error "$lastlog" "$flt" | tail -n +2
    fi
    echo "action:         $(remedy "${cls:-$state}")"
    [ -n "$lastlog" ] && { echo "lane log tail ($lastlog):"; tail -n 8 "$lastlog" | cut -c1-200 | sed 's/^/    /'; }
  fi
  rm -f "$flt"
  echo "VERDICT lane=$lane state=$state"
}

lane=${2:-}
case "${3:-}" in
  --stall) diagnose "$lane" stall ;;
  --sid) lane_sid "$lane" ;;
  *)
    if [ -n "$lane" ]; then diagnose "$lane"
    else
      for f in "$crew"/lanes/*.status; do
        [ -e "$f" ] || { echo "no lanes"; break; }
        l=$(basename "$f" .status); s=$(cat "$f")
        case "$s" in done) continue ;; esac
        diagnose "$l"; echo
      done
    fi ;;
esac
true
