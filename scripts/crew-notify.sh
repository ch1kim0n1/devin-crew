#!/usr/bin/env bash
# Best-effort desktop notification for agents without a push tool (Claude Code has PushNotification; use that there).
#   bash crew-notify.sh "devin-crew: lane api stopped, Devin usage limit, resets 14:30. Fix or say retry."
# macOS: osascript; Linux: notify-send; otherwise prints to stderr. Never fails.
msg=${1:-devin-crew needs you}
case "$(uname -s)" in
  Darwin) osascript -e "display notification \"${msg//\"/\\\"}\" with title \"devin-crew\"" >/dev/null 2>&1;;
  Linux) command -v notify-send >/dev/null 2>&1 && notify-send "devin-crew" "$msg" >/dev/null 2>&1 || echo "notify: $msg" >&2;;
  *) echo "notify: $msg" >&2;;
esac
exit 0
