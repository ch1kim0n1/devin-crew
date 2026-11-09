#!/usr/bin/env bash
# Per-lane effort table from events.log: launches, resumes, nudges, hung-tool kills, stalls, elapsed, last status.
#   bash crew-report.sh <project>
set -u
proj=$(cd "$1" && pwd) || exit 2
log="$proj/.devin-crew/events.log"
[ -s "$log" ] || { echo "no events yet"; exit 0; }
printf "%-10s %6s %7s %6s %5s %6s %7s  %s\n" lane launch resume nudge hung stall secs "last status"
awk '
{ l=$3; if (l == "router") next; m=$0; sub(/^[^ ]+ [^ ]+ [^ ]+ /,"",m); seen[l]=1
  if (m ~ /^launch/) L[l]++
  else if (m ~ /^resume/) R[l]++
  else if (m ~ /^NUDGE/) N[l]++
  else if (m ~ /^HUNG-TOOL/) H[l]++
  else if (m ~ /^STALL/) S[l]++
  else if (m ~ /^TIMEOUT/) T[l]++
  if (m ~ /^exit status=/) {
    s=m; sub(/^exit status=/,"",s); sub(/ session=.*$/,"",s); st[l]=s
    if (match(m,/elapsed=[0-9]+/)) E[l]+=substr(m,RSTART+8,RLENGTH-8)
  }
}
END {
  for (l in seen) printf "%-10s %6d %7d %6d %5d %6d %7d  %s\n", l, L[l], R[l], N[l], H[l], S[l], E[l], (l in st ? st[l] : "-")
}' "$log" | sort
