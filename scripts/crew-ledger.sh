#!/usr/bin/env bash
# Append one line to the cross-project usage ledger (read by crew-analytics.sh). Never fails the caller.
#   bash crew-ledger.sh turn <project> <lane> <status> <elapsed_s> <nudges> <resumed 0|1> <error_class|-> <session_id>
#   bash crew-ledger.sh qa   <project> <lane> <class> <severity>
# Ledger: $CREW_LEDGER, default <skill>/usage/ledger.tsv (git-ignored, local only). CREW_LEDGER=off disables.
# Token numbers come from Devin's own session store and are CUMULATIVE per session; crew-analytics keeps the latest row per lane.
#   peak = largest context size seen, in = sum of context sizes at each model call (input tokens, uncached estimate),
#   out = assistant characters / 4 (estimate), tools = tool calls, msgs = records, acu = Devin's own cost counter.
here="$(cd "$(dirname "$0")/.." && pwd)"
L=${CREW_LEDGER:-$here/usage/ledger.tsv}
[ "$L" = off ] && exit 0
mkdir -p "$(dirname "$L")" 2>/dev/null || exit 0
kind=${1:-}; proj=$(cd "${2:-.}" && pwd -P) || exit 0; lane=${3:-}; ts=$(date +%s)
case "$kind" in
  qa) printf 'qa\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$proj" "$lane" "${4:-other}" "${5:-LOW}" >> "$L";;
  turn)
    status=${4:-}; el=${5:-0}; nud=${6:-0}; res=${7:-0}; cls=${8:--}; sid=${9:-}
    DB=${DEVIN_SESSIONS_DB:-$HOME/.local/share/devin/cli/sessions.db}
    peak=0; in=0; out=0; tools=0; msgs=0; acu=0
    if [ -n "$sid" ] && [ -f "$DB" ]; then
      s=${sid//\'/}
      r=$(sqlite3 -readonly "$DB" "select
        ifnull((select max(json_extract(metadata,'\$.num_tokens_preceding')) from message_nodes where session_id='$s'),0)||'|'||
        ifnull((select sum(json_extract(metadata,'\$.num_tokens_preceding')) from message_nodes where session_id='$s'),0)||'|'||
        ifnull((select sum(length(json_extract(chat_message,'\$.content')))/4 from message_nodes where session_id='$s' and json_extract(chat_message,'\$.role')='assistant'),0)||'|'||
        (select count(*) from tool_call_state where session_id='$s')||'|'||
        (select count(*) from message_nodes where session_id='$s')||'|'||
        ifnull((select json_extract(metadata,'\$.total_acu_cost') from sessions where id='$s'),0)" 2>/dev/null)
      [ -n "$r" ] && IFS='|' read -r peak in out tools msgs acu <<< "$r"
    fi
    td=0; tt=0
    if [ -f "$proj/.devin-crew/TASKS.md" ]; then
      td=$(grep -Ec '^\|.*\| *done *\|? *$' "$proj/.devin-crew/TASKS.md")
      tt=$(grep -Ec '^\|.*\| *(open|running|review|done|failed) *\|? *$' "$proj/.devin-crew/TASKS.md")
    fi
    printf 'turn\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$proj" "$lane" "$status" "$el" "$nud" "$res" "$cls" \
      "${peak:-0}" "${in:-0}" "${out:-0}" "${tools:-0}" "${msgs:-0}" "${acu:-0}" "$td" "$tt" >> "$L";;
esac
exit 0
