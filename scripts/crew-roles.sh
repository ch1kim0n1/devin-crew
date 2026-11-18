#!/usr/bin/env bash
# The crew's team: which role fits which files, and which specialist reviewers a change needs.
#   bash crew-roles.sh list                          every role with its one-line job
#   bash crew-roles.sh pick <project> <task-id>      role for a task, from its scope globs (templates/roles.map); implementer if unknown
#   bash crew-roles.sh pick-scope "<glob> <glob>..." same, from globs directly
#   bash crew-roles.sh specialists <project>         specialist reviewers for the change now in the tree: security | a11y | performance (space-separated, may be empty)
# env: CREW_SPECIALISTS="security a11y performance" or "none" overrides the automatic choice.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"; map="$here/templates/roles.map"
pick_scope() {
  local globs=$1 g role pat first="" cnt_best=0 best=""
  set -f   # scope globs are data: never expand them against the current directory
  declare -a seen=(); declare -a cnt=()
  for g in $globs; do
    role=""
    while IFS=$'\t' read -r r pats; do case "$r" in ""|\#*) continue;; esac
      for pat in $pats; do
        # shellcheck disable=SC2254
        case "$g" in $pat) role=$r; break;; esac
      done; [ -n "$role" ] && break
    done < "$map"
    [ -z "$role" ] && continue
    local i found=-1; for i in "${!seen[@]}"; do [ "${seen[$i]}" = "$role" ] && found=$i; done
    if [ "$found" -ge 0 ]; then cnt[found]=$(( ${cnt[$found]} + 1 )); else seen+=("$role"); cnt+=(1); fi
    : "${first:=$role}"
  done
  local i; for i in "${!seen[@]}"; do [ "${cnt[$i]}" -gt "$cnt_best" ] && { cnt_best=${cnt[$i]}; best=${seen[$i]}; }; done
  set +f; echo "${best:-implementer}"
}
case "${1:-}" in
  list) for f in "$here"/templates/roles/*.md; do printf '%-12s %s\n' "$(basename "$f" .md)" "$(head -1 "$f" | sed -E 's/^ROLE: [a-z0-9-]+( \([^)]*\))?\. ?//' | cut -c1-110)"; done;;
  pick-scope) pick_scope "${2:-}";;
  pick)
    proj=$(cd "$2" && pwd -P) || exit 2; id=${3:?task id}
    sc=$(awk -F'|' -v id="$id" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 && t($2)==id {print t($4)}' "$proj/.devin-crew/TASKS.md" 2>/dev/null | head -1)
    lane=$(awk -F'|' -v id="$id" 'function t(x){gsub(/^[ \t]+|[ \t]+$/,"",x);return x} NF>=7 && t($2)==id {print t($3)}' "$proj/.devin-crew/TASKS.md" 2>/dev/null | head -1)
    g=$(awk -F'\t' -v l="$lane" '$1==l{printf "%s ", $2}' "$proj/.devin-crew/scopes.txt" 2>/dev/null)
    pick_scope "${g:-$sc}";;
  specialists)
    proj=$(cd "$2" && pwd -P) || exit 2
    case "${CREW_SPECIALISTS:-auto}" in none) exit 0;; auto) ;; *) echo "$CREW_SPECIALISTS"; exit 0;; esac
    files=$( { git -C "$proj" status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.{3}//; s/.* -> //'; } | grep -v '^\.devin-crew/' )
    [ -n "$files" ] || exit 0
    out=""
    printf '%s\n' "$files" | grep -qE '\.(py|go|rs|java|rb|php|cs|ts|tsx|js|jsx|swift|kt|c|cc|cpp|h|sh|sql)$' && out="security"
    printf '%s\n' "$files" | grep -qE '\.(tsx|jsx|vue|svelte|html|css|scss|swift|kt|dart)$' && out="$out a11y"
    lines=$(git -C "$proj" diff HEAD --shortstat 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+'); lines=${lines:-0}
    { [ "$lines" -ge 400 ] || printf '%s\n' "$files" | grep -qE '\.sql$|migrations/|perf|bench'; } && out="$out performance"
    echo "${out# }";;
  *) sed -n 2,7p "$0"; exit 2;;
esac
