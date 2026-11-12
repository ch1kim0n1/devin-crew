#!/usr/bin/env bash
# Install or update the devin-crew skill for Claude Code.
#   curl -fsSL https://raw.githubusercontent.com/ch1kim0n1/devin-crew/main/install.sh | bash
#   bash install.sh [target_dir]       default target: ~/.claude/skills/devin-crew
# Only touches the target directory. Re-running updates it (fast-forward only; it never discards local changes).
set -eu
dest=${1:-$HOME/.claude/skills/devin-crew}
repo=https://github.com/ch1kim0n1/devin-crew
missing=""; for t in bash git python3 sqlite3 tar; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
[ -z "$missing" ] || { echo "missing required tools:$missing (install them, then re-run)" >&2; exit 1; }
if [ -d "$dest/.git" ]; then
  git -C "$dest" pull --ff-only && echo "updated $dest"
elif [ -e "$dest" ]; then
  echo "$dest exists and is not a git checkout: move it away or pass another target" >&2; exit 1
else
  mkdir -p "$(dirname "$dest")"; git clone --depth 1 "$repo" "$dest" && echo "installed $dest"
fi
command -v devin >/dev/null 2>&1 || echo "note: Devin CLI not found. Install it and run 'devin auth login' before using the skill."
echo "next: restart Claude Code, then type /devin-crew. Check your setup anytime with: bash $dest/scripts/crew-doctor.sh <project>"
