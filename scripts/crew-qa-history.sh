#!/usr/bin/env bash
# Memory of what QA found in earlier milestones, so later milestones check repeat offenders harder.
#   bash crew-qa-history.sh <project> add <milestone> <lane> <class> <HIGH|MED|LOW> "<text>"
#   bash crew-qa-history.sh <project> show    counts by class and lane, plus the watch list
#   bash crew-qa-history.sh <project> watch   only the watch list (empty when nothing repeats); crew-qa.sh prints this
# Classes: stub skipped-test weak-test error-path missed-requirement stale-contract scope security docs-drift integration other
# Watch rule: a class seen 2+ times or ever HIGH; a lane with 2+ findings; a lane that needed a nudge or hung-tool kill.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
cmd=${2:-show}; shift 2 2>/dev/null
crew="$proj/.devin-crew"; h="$crew/QA-HISTORY.tsv"
classes=" stub skipped-test weak-test error-path missed-requirement stale-contract scope security docs-drift integration other "

watch_lines() {
  [ -s "$h" ] && awk -F'\t' '
    { c[$3]++; l[$2]++; if ($4=="HIGH") hi[$3]=1 }
    END {
      for (k in c) if (c[k]>=2 || hi[k]) printf "class %s: seen %dx%s -> check it first in every lane\n", k, c[k], (hi[k]?" (HIGH at least once)":"")
      for (k in l) if (l[k]>=2) printf "lane %s: %d findings so far -> read its diff line by line\n", k, l[k]
    }' "$h" | sort
  if [ -s "$crew/events.log" ]; then
    awk '$4=="NUDGE" || $4=="HUNG-TOOL" {n[$3]++} END{for (k in n) printf "lane %s: needed rescue %dx (nudge/hung-tool kill) -> it may have skipped the part where it stalled\n", k, n[k]}' "$crew/events.log" | sort
  fi
  true
}

case "$cmd" in
  add)
    [ $# -ge 5 ] || { echo "usage: add <milestone> <lane> <class> <HIGH|MED|LOW> \"<text>\"" >&2; exit 2; }
    m=$1; lane=$2; cls=$3; sev=$4; text=$(printf '%s' "$5" | tr '\t\n' '  ')
    case "$classes" in *" $cls "*) ;; *) echo "unknown class '$cls'; use:$classes" >&2; exit 2;; esac
    case "$sev" in HIGH|MED|LOW) ;; *) echo "severity must be HIGH, MED or LOW" >&2; exit 2;; esac
    mkdir -p "$crew"; printf '%s\t%s\t%s\t%s\t%s\n' "$m" "$lane" "$cls" "$sev" "$text" >> "$h"
    bash "$(dirname "$0")/crew-ledger.sh" qa "$proj" "$lane" "$cls" "$sev"
    echo "recorded: $m $lane $cls $sev";;
  show)
    if [ ! -s "$h" ]; then echo "QA history: no findings recorded yet"
    else
      echo "QA history: $(wc -l < "$h" | tr -d ' ') finding(s) over $(cut -f1 "$h" | sort -u | wc -l | tr -d ' ') milestone(s)"
      echo "by class: $(cut -f3 "$h" | sort | uniq -c | sort -rn | awk '{printf "%s %s | ", $2, $1}')"
      echo "by lane:  $(cut -f2 "$h" | sort | uniq -c | sort -rn | awk '{printf "%s %s | ", $2, $1}')"
    fi
    w=$(watch_lines); [ -n "$w" ] && { echo "WATCH:"; echo "$w" | sed 's/^/  /'; }
    true;;
  watch) watch_lines;;
  *) echo "usage: crew-qa-history.sh <project> add|show|watch" >&2; exit 2;;
esac
