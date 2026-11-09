#!/usr/bin/env bash
# Mail between lanes. One file per lane: .devin-crew/inbox/<lane>.md, plus a cursor of lines already delivered.
#   bash lane-msg.sh <project> send <from> <to> "<text>"   append to <to>'s inbox and to BOARD.md
#   bash lane-msg.sh <project> read <lane>                  print unread mail for <lane>, advance its cursor
#   bash lane-msg.sh <project> pending                      "<lane> <status> <unread>" for every lane with unread mail
set -u
proj=$(cd "$1" && pwd) || exit 2
cmd=$2; shift 2
crew="$proj/.devin-crew"; inbox="$crew/inbox"
mkdir -p "$inbox"

case "$cmd" in
  send)
    from=$1; to=$2; text=$(printf '%s' "$3" | tr '\n' ' ')
    line="[$from -> $to] $text"
    printf '%s\n' "$line" >> "$inbox/$to.md"   # ponytail: single-line O_APPEND write, atomic enough; no lock
    printf '%s\n' "$line" >> "$crew/BOARD.md"
    echo "sent to $to"
    ;;
  read)
    lane=$1; f="$inbox/$lane.md"; cur="$inbox/$lane.cursor"
    total=$( (wc -l < "$f") 2>/dev/null || echo 0); total=${total//[[:space:]]/}
    seen=$(cat "$cur" 2>/dev/null || echo 0)
    if [ "$total" -gt "$seen" ]; then tail -n +"$((seen + 1))" "$f"; else echo "(no new mail)"; fi
    echo "$total" > "$cur"
    ;;
  pending)
    for f in "$inbox"/*.md; do
      [ -e "$f" ] || continue
      lane=$(basename "$f" .md)
      total=$(wc -l < "$f"); total=${total//[[:space:]]/}
      seen=$(cat "$inbox/$lane.cursor" 2>/dev/null || echo 0)
      [ "$total" -gt "$seen" ] && echo "$lane $(cat "$crew/lanes/$lane.status" 2>/dev/null || echo not-started) $((total - seen))"
    done
    true
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
