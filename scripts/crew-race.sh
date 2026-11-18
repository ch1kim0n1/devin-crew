#!/usr/bin/env bash
# Best-of-2 for a risky task: two Devins solve the same task independently in their own worktrees; the conductor merges only the better one.
#   bash crew-race.sh <project> <task-id>
# Run it after crew-init (worktree mode only) and before the conductor launches that task. It adds the twin row <id>-alt on lane <lane>-alt (same scope,
# depends, acceptance and brief), its scope lines and its worktree, and records the pair in .devin-crew/race/<id>. The conductor then holds both
# lanes at `raced`; when both are clean (acceptance, scope, reviewer) it keeps the one with fewer reviewer findings, then the smaller diff, merges it,
# discards the other and marks both tasks done.
set -u
proj=$(cd "$1" && pwd -P) || exit 2
id=${2:?task id}; here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"
[ "$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" = "$proj" ] || { echo "RACE STOP: needs worktree mode (a git repo root)"; exit 1; }
row=$(awk -F'|' -v id="$id" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 && t($2)==id {print; exit}' "$crew/TASKS.md")
[ -n "$row" ] || { echo "RACE STOP: no task $id in TASKS.md"; exit 1; }
IFS='|' read -r _ _ lane scope dep acc _ <<< "$row"; lane=$(echo $lane); alt="$lane-alt"
[ -s "$crew/prompts/$id.md" ] || { echo "RACE STOP: no brief prompts/$id.md"; exit 1; }
[ -e "$crew/race/$id" ] && { echo "already racing: $(cat "$crew/race/$id")"; exit 0; }
mkdir -p "$crew/race"
printf '| %s-alt | %s | %s | %s | %s | open |\n' "$id" "$alt" "$(echo $scope)" "$(echo $dep)" "$(echo $acc)" >> "$crew/TASKS.md"
awk -F'\t' -v l="$lane" -v a="$alt" '$1==l{print a "\t" $2}' "$crew/scopes.txt" >> "$crew/scopes.txt"
{ cat "$crew/prompts/$id.md"; printf '\nNote: another Devin solves this same task independently in its own worktree; only the better result is merged. Stay inside your own directory and do not wait for it.\n'; } > "$crew/prompts/$id-alt.md"
[ -s "$crew/prompts/$id.role" ] && cp "$crew/prompts/$id.role" "$crew/prompts/$id-alt.role"
bash "$here/crew-worktree.sh" "$proj" add "$lane" >/dev/null 2>&1; bash "$here/crew-worktree.sh" "$proj" add "$alt" >/dev/null 2>&1
echo "$lane $alt" > "$crew/race/$id"; echo "RACE $id: $lane vs $alt"
