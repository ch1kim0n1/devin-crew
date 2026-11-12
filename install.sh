#!/usr/bin/env bash
# Install or update the devin-crew skill for Claude Code.
#   curl -fsSL https://raw.githubusercontent.com/ch1kim0n1/devin-crew/main/install.sh | bash
#   bash install.sh [target_dir]       default target: ~/.claude/skills/devin-crew
#   bash install.sh --devin            for Devin CLI as the manager: ~/.config/devin/skills/devin-crew (Devin already reads ~/.claude/skills through its Claude importer, so an existing Claude install needs nothing)
#   bash install.sh --codex            for Codex: ~/.codex/skills/devin-crew (links an existing Claude install instead of cloning twice)
# Only touches the target directory. Re-running updates it (fast-forward only; it never discards local changes).
set -eu
codex=0; devin_mgr=0
case "${1:-}" in --codex) codex=1; shift;; --devin) devin_mgr=1; shift;; esac
dest=${1:-$HOME/.claude/skills/devin-crew}
if [ "$devin_mgr" = 1 ]; then
  dest=${1:-$HOME/.config/devin/skills/devin-crew}
  if [ ! -e "$dest" ] && [ -d "$HOME/.claude/skills/devin-crew/.git" ]; then
    echo "Devin already loads skills from ~/.claude/skills through its Claude importer: devin-crew is visible there. Nothing to install."
    echo "Type /devin-crew in Devin. Read $HOME/.claude/skills/devin-crew/reference/devin.md first (permissions, waiting, model)."; exit 0
  fi
fi
if [ "$codex" = 1 ]; then
  dest=${1:-$HOME/.codex/skills/devin-crew}
  if [ ! -e "$dest" ] && [ -d "$HOME/.claude/skills/devin-crew/.git" ]; then
    mkdir -p "$(dirname "$dest")"; ln -s "$HOME/.claude/skills/devin-crew" "$dest"
    echo "linked $dest -> $HOME/.claude/skills/devin-crew. In Codex use \$devin-crew (or /skills). Read reference/codex.md for the sandbox settings."; exit 0
  fi
fi
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
[ "$devin_mgr" = 1 ] && echo "Devin: type /devin-crew; read $dest/reference/devin.md first (permissions, waiting, model)."
[ "$codex" = 1 ] && echo "Codex: use \$devin-crew (or /skills); read $dest/reference/codex.md for the sandbox settings (devin needs the network)."
echo "next: restart Claude Code (or Codex), then type /devin-crew (\$devin-crew in Codex). Check your setup anytime with: bash $dest/scripts/crew-doctor.sh <project>"
