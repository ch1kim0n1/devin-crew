#!/usr/bin/env bash
# Mechanical QA net over everything the crew changed. It catches what fast coders leave behind; it is NOT the QA
# (see reference/qa-checklist.md for what only you can check). Exit 1 if any HIGH finding.
#   bash crew-qa.sh <project>
# Git repo: diff of the working tree vs HEAD plus untracked files. Otherwise: diff vs .devin-crew/snapshot.tgz.
set -u
proj=$(cd "$1" && pwd) || exit 2
cd "$proj" || exit 2
crew="$proj/.devin-crew"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# ---- 1. one unified diff, zero context
if git rev-parse --show-toplevel >/dev/null 2>&1 && [ "$(git rev-parse --show-toplevel)" = "$proj" ]; then
  { git diff HEAD -U0 --no-color --src-prefix=a/ --dst-prefix=b/ -- . ':!.devin-crew'
    git ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do
      case "$f" in .devin-crew/*) continue ;; esac
      git diff --no-index -U0 --no-color --src-prefix=a/ --dst-prefix=b/ /dev/null "$f"
    done
  } > "$work/diff.txt" 2>/dev/null
elif [ -f "$crew/snapshot.tgz" ]; then
  mkdir -p "$work/old"; tar -xzf "$crew/snapshot.tgz" -C "$work/old"
  diff -ruN -U0 -x node_modules -x .git -x .devin-crew -x dist -x build -x .next -x target -x venv -x .venv -x __pycache__ "$work/old" "$proj" 2>/dev/null \
    | sed "s|^+++ $proj/|+++ b/|; s|^--- $work/old/|--- a/|" > "$work/diff.txt"
else
  echo "crew-qa: not a git repo root and no snapshot to diff against" >&2; exit 2
fi

# ---- 2. split into added lines (file:line:text), removed lines, deleted files
awk -v out="$work" '
  /^--- / { old=$2; sub(/^a\//,"",old); next }
  /^\+\+\+ / { f=$2; sub(/^b\//,"",f); if (f=="/dev/null") print old > (out "/deleted.txt"); next }
  /^@@/ { match($0,/\+[0-9]+/); ln=substr($0,RSTART+1,RLENGTH-1)+0; next }
  /^\+/ { print f ":" ln ":" substr($0,2) > (out "/added.txt"); ln++; next }
  /^-/  { print f ":" substr($0,2) > (out "/removed.txt") }
' "$work/diff.txt"
touch "$work/added.txt" "$work/removed.txt" "$work/deleted.txt"
cut -d: -f1 "$work/added.txt" | sort -u > "$work/changed.txt"
sort -u "$work/deleted.txt" >> "$work/changed.txt"; sort -u -o "$work/changed.txt" "$work/changed.txt"

if [ ! -s "$work/changed.txt" ]; then echo "crew-qa: no changes found"; exit 0; fi
nfiles=$(wc -l < "$work/changed.txt" | tr -d ' '); nadd=$(wc -l < "$work/added.txt" | tr -d ' '); nrem=$(wc -l < "$work/removed.txt" | tr -d ' ')
echo "crew-qa: $nfiles files changed, +$nadd/-$nrem lines"

high=0; med=0
TESTRE='(^|/)(tests?|__tests__|spec|specs)/|(^|/)(test_[^/]*|[^/]*_test|[^/]*\.(test|spec))\.[a-z]+:'
DOCRE='\.(md|txt|rst)(:|$)'
note() { # severity label
  [ "$1" = HIGH ] && high=$((high + 1)) || med=$((med + 1))
  echo "[$1] $2"
}
hit() { # severity label regex [skip-regex]
  local out
  out=$(grep -E -i -- "$3" "$work/added.txt" | { if [ -n "${4:-}" ]; then grep -Ev -- "$4"; else cat; fi; } | head -6)
  [ -n "$out" ] && { note "$1" "$2"; echo "$out" | cut -c1-160 | sed 's/^/      /'; }
  return 0
}

# ---- 3. patterns on added lines
hit HIGH "possible secret committed" 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|(api[_-]?key|secret|token|passwd|password)["'"'"']? *[:=] *["'"'"'][A-Za-z0-9/+_-]{16,}["'"'"']'
hit HIGH "stub / unfinished implementation" 'NotImplemented|not implemented|todo: *implement|pass *# *(todo|fixme)|unimplemented!|todo!\(|throw new Error\(.(todo|stub)'
hit HIGH "skipped / focused / disabled tests" '\.only\(|\bf(it|describe)\(|\bx(it|describe)\(|(it|test|describe)\.skip|@(unittest\.)?skip|pytest\.mark\.(skip|xfail)|t\.Skip\(|@Disabled|#\[ignore\]'
hit MED "swallowed errors" 'except[^:]*: *pass|catch *\([^)]*\) *\{ *\}|rescue *(nil|$)|\|\| *true'
hit MED "lint/type/hook suppressions" 'eslint-disable|@ts-ignore|@ts-nocheck|# *type: *ignore|# *noqa|# *pylint: *disable|nolint|--no-verify|#\[allow'
hit MED "debug leftovers" 'console\.(log|debug)\(|\bdebugger\b|breakpoint\(\)|import +pdb|pdb\.set_trace|binding\.pry|dbg!\(|var_dump\(|System\.out\.println' "$TESTRE|$DOCRE"
hit MED "TODO/FIXME/HACK markers added" '\b(TODO|FIXME|XXX|HACK)\b' "$DOCRE"
hit MED "hardcoded local host or path" 'localhost|127\.0\.0\.1|/Users/[a-z]|C:\\Users' "$TESTRE|$DOCRE"
hit MED "placeholder text" 'lorem ipsum|changeme|your[-_ ]?(api[-_ ]?)?key[-_ ]?here|foo@bar|\basdf\b'

# ---- 4. file-level checks
classify() { grep -E "$1" "$work/changed.txt" || true; }
tests=$(grep -E "$TESTRE" <(sed 's/$/:/' "$work/changed.txt") | sed 's/:$//' || true)
src=$(grep -E '\.(py|js|jsx|ts|tsx|go|rs|java|kt|rb|php|swift|c|cc|cpp|h|cs|sh)$' "$work/changed.txt" | grep -Ev "$TESTRE" || true)
if [ -n "$src" ] && [ -z "$tests" ]; then note MED "source files changed but no test file changed"; echo "$src" | head -5 | sed 's/^/      /'; fi

if [ -s "$work/deleted.txt" ]; then
  dt=$(grep -E "$TESTRE" <(sed 's/$/:/' "$work/deleted.txt") | sed 's/:$//' || true)
  [ -n "$dt" ] && { note HIGH "test files deleted"; echo "$dt" | sed 's/^/      /'; }
  note MED "files deleted (confirm the task asked for it)"; head -5 "$work/deleted.txt" | sed 's/^/      /'
fi

ASSERT='assert|expect\(|should|\.equal|toBe|toEqual|t\.(Error|Fatal)|require\.|self\.assert'
ra=$(grep -E "$TESTRE" "$work/removed.txt" | grep -Eic "$ASSERT" || true)
aa=$(grep -E "$TESTRE" "$work/added.txt" | grep -Eic "$ASSERT" || true)
[ "${ra:-0}" -gt "${aa:-0}" ] && note HIGH "test assertions net decreased (removed $ra, added $aa): tests weakened"

for f in $tests; do
  [ -f "$f" ] || continue
  c=$(grep -Eic "$ASSERT" "$f" || true)
  [ "${c:-0}" -eq 0 ] && { note HIGH "test file with zero assertions: $f"; }
done

man=$(grep -E '(^|/)(package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|requirements[^/]*\.txt|pyproject\.toml|poetry\.lock|Pipfile(\.lock)?|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|Gemfile(\.lock)?|composer\.json|pom\.xml|build\.gradle)$' "$work/changed.txt" || true)
[ -n "$man" ] && { note MED "dependency manifest/lockfile changed (was it in the task?)"; echo "$man" | sed 's/^/      /'; }

junk=$(grep -E '(^|/)(\.env($|\.[^e])|[^/]*\.pem|[^/]*\.key|id_rsa[^/]*)$' "$work/changed.txt" || true)
[ -n "$junk" ] && { note HIGH "secret-like files added"; echo "$junk" | sed 's/^/      /'; }
junk=$(grep -E '(\.DS_Store|\.pyc|\.log|\.swp|\.orig|\.rej|~)$' "$work/changed.txt" || true)
[ -n "$junk" ] && { note MED "stray files"; echo "$junk" | sed 's/^/      /'; }

big=$(cut -d: -f1 "$work/added.txt" | sort | uniq -c | awk '$1>800{print $2" ("$1" lines)"}')
[ -n "$big" ] && { note MED "very large additions (generated or pasted?)"; echo "$big" | sed 's/^/      /'; }

echo "crew-qa: HIGH=$high MED=$med  (a clean run proves little; run the manual checklist)"
[ "$high" -eq 0 ]
