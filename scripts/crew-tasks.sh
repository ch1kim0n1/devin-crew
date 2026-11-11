#!/usr/bin/env bash
# Keep TASKS.md statuses true without hand edits. Only the last cell of a row changes.
#   bash crew-tasks.sh <project> set <id> <status>              one task
#   bash crew-tasks.sh <project> lane <lane> <from|from2> <to>  every task of a lane whose status is one of <from>
#   bash crew-tasks.sh <project> next                           open tasks that can launch now (deps done, lane not running)
# Statuses: open | running | review (lane exited ok, not yet verified) | done | failed
# Row format: | id | lane | scope | depends | acceptance | status |
set -u
proj=$(cd "$1" && pwd -P) || exit 2
cmd=${2:-}; shift 2 2>/dev/null
f="$proj/.devin-crew/TASKS.md"
[ -f "$f" ] || exit 0

rewrite() { # awk program body deciding the new status in variable ns; vars passed with -v
  local tmp="$f.tmp.$$"
  awk -F'|' -v OFS='|' "$@" > "$tmp" && mv "$tmp" "$f"
}

case "$cmd" in
  set)
    id=$1; st=$2
    rewrite -v id="$id" -v st="$st" '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x); return x}
      NF>=7 && t($2)==id { s=(t($NF)=="")?NF-1:NF; $s=" " st " " }
      {print}' "$f";;
  lane)
    lane=$1; from=$2; st=$3
    rewrite -v lane="$lane" -v from="|$from|" -v st="$st" '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x); return x}
      { s=(t($NF)=="")?NF-1:NF }
      NF>=7 && t($3)==lane && index(from, "|" t($s) "|") { $s=" " st " " }
      {print}' "$f";;
  next)
    crew="$proj/.devin-crew"
    awk -F'|' '
      function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x); return x}
      NF>=7 { id=t($2); if (id=="id" || id ~ /^-/ || id=="") next; s=(t($NF)=="")?NF-1:NF; st[id]=t($s); lane[id]=t($3); dep[id]=t($5); ids[++n]=id }
      END { for (i=1;i<=n;i++) { id=ids[i]; if (st[id]!="open") continue
              ok=1; m=split(dep[id], d, /[ ,]+/)
              for (j=1;j<=m;j++) if (d[j]!="" && d[j]!="-" && st[d[j]]!="done") ok=0
              if (ok) print id, lane[id] } }' "$f" | while read -r id lane; do
        s=$(cat "$crew/lanes/$lane.status" 2>/dev/null || echo none)
        [ "$s" = running ] || echo "$id $lane"
      done;;
  *) echo "usage: crew-tasks.sh <project> set|lane|next ..." >&2; exit 2;;
esac
