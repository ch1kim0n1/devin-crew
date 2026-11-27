#!/usr/bin/env bash
# From a vague goal to a running crew, with a read-only architect Devin doing the thinking and writing, so the brain only reviews and decides.
#   bash crew-plan.sh <project> draft "<goal>" [--answers "<text>"] [--print]   launch the architect Devin (lane plan, read-only, role architect); it writes .devin-crew/draft/*
#   bash crew-plan.sh <project> check                                           validate the draft; prints a short summary and the questions (exit 1 on problems)
#   bash crew-plan.sh <project> apply [--ship] [--budget <minutes>]             move the draft into place (PLAN.md, scopes, contracts, roster, briefs, milestones)
#   bash crew-plan.sh <project> go [--ship] [--budget <minutes>]                apply + crew-init (preflight, lock, baseline, isolation) + autopilot --detach
# The draft is read-only recon output: no worker is launched and nothing in the project changes before `go`. `--ship` writes `ship: yes` into PLAN.md
# (the user's word that the crew may push a branch and open a PR). Draft files, all under .devin-crew/draft/:
#   RECON.md  QUESTIONS.md (at most 3 `Q: ... | default: ...` lines, or NONE)  PLAN.md  SPEC.md  CONTRACTS.md  ROSTER.md  scopes.txt  baseline.cmd
#   milestones/m<N>.tasks (a first line `# name`, then TASKS rows)  prompts/<task-id>.md (+ optional <task-id>.role)
set -u
proj=$(cd "$1" && pwd -P) || exit 2
mode=${2:-}; shift 2 2>/dev/null
here="$(cd "$(dirname "$0")" && pwd)"; crew="$proj/.devin-crew"; dr="$crew/draft"
trim() { local x=$1; x=${x#"${x%%[![:space:]]*}"}; echo "${x%"${x##*[![:space:]]}"}"; }
case "$mode" in
  draft)
    goal=${1:-}; shift; ans=""; print=0
    while [ $# -gt 0 ]; do case "$1" in --answers) ans=$2; shift 2;; --print) print=1; shift;; *) shift;; esac; done
    [ -n "$goal" ] || { echo "usage: crew-plan.sh <project> draft \"<goal>\" [--answers \"<text>\"]" >&2; exit 2; }
    mkdir -p "$dr/milestones" "$dr/prompts" "$crew/prompts" "$crew/lanes"
    n=1; while [ -e "$crew/prompts/plan-$n.md" ]; do n=$((n + 1)); done; brief="$crew/prompts/plan-$n.md"
    roles=$(bash "$here/crew-roles.sh" list | cut -c1-90)
    cat > "$brief" <<BRIEF
Plan this goal for a Devin crew working in this project ($proj): $goal
${ans:+The user answered your clarifying questions: $ans
Update the draft accordingly (QUESTIONS.md becomes NONE unless something new is truly blocking).
}Study the project first. Then write ONLY these files under $dr (create the folders):
1. RECON.md: at most 30 lines: layout, languages, how tests/build/lint run (exact commands you saw), conventions, git state, risks.
2. QUESTIONS.md: at most 3 lines \`Q: <question> | default: <what you will assume>\`, only for things that change the plan materially and cannot be derived from the project; otherwise the single word NONE.
3. SPEC.md: the goal as a short numbered list of TESTABLE acceptance criteria (each checkable by a command or an observable behavior). "Done" means every one holds.
4. PLAN.md, one page, format: first line \`# Objective: <one sentence>\`, then goal/scope/out-of-scope, isolation (worktree for a git repo root, else shared), lanes (count and why; cap 5; lane name, role, owned files), milestones (M1..Mn: deliverable, tasks), QA plan, risks.
5. CONTRACTS.md: first line \`version: 1\`; every interface two lanes share (signatures, API shapes, file formats) with owner lane; or just the version line if lanes are fully independent.
6. ROSTER.md: per lane \`- <lane> (<role>): owns <globs>; consumers: <lanes>\`.
7. scopes.txt: \`<lane><TAB><glob relative to the project>\`, one line per owned path; no two lanes own the same file.
8. baseline.cmd: one line, the project's test/build command that should pass before work starts (or an honest \`true\` if none exists and the first task creates one).
9. milestones/m1.tasks, m2.tasks, ...: each milestone is verifiable on its own; first line \`# <milestone name>\`, then one row per task in the exact format \`| id | lane | scope | depends | acceptance | status |\` with status \`open\`, ids unique across milestones (t1, t2, ...), depends = \`-\` or ids, acceptance = ONE command that fails when the work is wrong (no pipes inside it; put longer checks in a script file the task creates).
10. prompts/<task-id>.md: one self-contained brief per task (goal, owned files, contracts to honor, the exact verify command, definition of done, what sibling lanes do at the same time). Optionally prompts/<task-id>.role holding one role name; if absent the role is picked from the task's files.
Roles you can assign (templates/roles/):
$roles
Rules: pair risky or contract-heavy work with a \`tests\` lane that writes tests from CONTRACTS.md in parallel (test-first); a \`tests\` task's depends lists the task(s) whose code its acceptance command runs (otherwise it is checked red before that code merges); never more lanes than independent file clusters; every task is small enough for one Devin turn of 5-45 minutes; the last milestone includes docs for what was built. You never edit project files.
BRIEF
    [ "$print" = 1 ] && { echo "brief: $brief"; cat "$brief"; exit 0; }
    # Devin refuses untrusted workspaces and this skill never bypasses that: find out now, once, before the architect is launched
    if [ ! -f "$crew/trusted" ]; then
      d=$(bash "$here/crew-doctor.sh" "$proj" --trust 2>&1); rc=$?
      if [ "$rc" -ne 0 ]; then printf '%s\n' "$d" | grep -E '^(FAIL|WARN)' | head -6; echo "PLAN STOP: preflight failed (fix above, e.g. run 'devin' once in $proj and accept the workspace trust); nothing was started"; exit 1; fi
      : > "$crew/trusted"
    fi
    echo "$proj" > "$crew/lanes/plan.workdir"; : > "$crew/lanes/plan.readonly"; rm -f "$dr/QUESTIONS.md" "$dr/PLAN.md"
    [ -f "$crew/BOARD.md" ] || : > "$crew/BOARD.md"
    CREW_ROLE=architect bash "$here/crew-launch.sh" "$proj" lane plan - "$brief";;
  check)
    bad=0; say() { echo "$*"; }; prob() { say "PROBLEM: $*"; bad=1; }
    for f in PLAN.md SPEC.md CONTRACTS.md ROSTER.md scopes.txt baseline.cmd QUESTIONS.md; do [ -s "$dr/$f" ] || prob "draft/$f missing or empty"; done
    lanes=""; graph=""; ntask=0; nm=0
    istest() { [ "$1" = tests ] || grep -q "^- $1 (tests)" "$dr/ROSTER.md" 2>/dev/null || [ "$(head -1 "$dr/prompts/$2.role" 2>/dev/null)" = tests ]; }
    for mf in "$dr"/milestones/m*.tasks; do
      [ -f "$mf" ] || continue
      milestone=${mf##*/m}; milestone=${milestone%.tasks}
      case "$milestone" in ''|0*|*[!0-9]*) prob "invalid milestone file: ${mf##*/}"; continue;; esac
      nm=$((nm + 1)); other=0; loose=""
      while IFS= read -r row || [ -n "$row" ]; do
        case "$row" in '|'*) ;; *) continue;; esac
        IFS='|' read -r _ id lane _ dep acc st _ <<< "$row"
        id=$(trim "$id"); lane=$(trim "$lane"); dep=$(trim "$dep"); st=$(trim "$st")
        case "$id" in id|-*|:*|"") continue;; esac
        ntask=$((ntask + 1)); lanes="$lanes$lane"$'\n'
        graph+="$id|$milestone|$dep"$'\n'
        [ -n "$st" ] || prob "$id: no status cell"
        [ -s "$dr/prompts/$id.md" ] || prob "$id: no brief prompts/$id.md"
        grep -q "^$lane	" "$dr/scopes.txt" 2>/dev/null || prob "$id: lane $lane has no scope in scopes.txt"
        [ -n "$(trim "$acc")" ] || prob "$id: empty acceptance command"
        [ -s "$dr/prompts/$id.role" ] && { r=$(head -1 "$dr/prompts/$id.role"); [ -f "$here/../templates/roles/$r.md" ] || prob "$id: unknown role $r"; }
        if istest "$lane" "$id"; then
          case "$dep" in ''|-) loose="$loose $id";; esac
        else other=1; fi
      done < "$mf"
      [ "$other" = 1 ] && for id in $loose; do prob "$id: tests task with no depends; list the task(s) whose code its acceptance runs"; done
    done
    [ "$nm" -gt 0 ] || prob "no milestones/m<N>.tasks"
    # Check dependencies against the scheduler's milestone order, then visit each task to detect cycles.
    while IFS= read -r problem; do prob "$problem"; done < <(printf '%s' "$graph" | awk -F '|' '
      function visit(id,    i, n, deps, dep) {
        state[id]=1
        n=split(dependencies[id], deps, /[ ,]+/)
        for (i=1; i<=n; i++) {
          dep=deps[i]
          if (dep=="" || dep=="-") continue
          if (!(dep in milestone)) print id " depends on unknown task " dep
          else if (milestone[dep] > milestone[id]) print id " depends on later milestone task " dep
          else if (state[dep]==1) print "dependency cycle: " id " depends on " dep
          else if (!state[dep]) visit(dep)
        }
        state[id]=2
      }
      { if ($1 in milestone) print "duplicate task ID: " $1
        milestone[$1]=$2+0; dependencies[$1]=$3; ids[++count]=$1 }
      END { for (i=1; i<=count; i++) if (!state[ids[i]]) visit(ids[i]) }')
    nlu=$(printf '%s' "$lanes" | sort -u | grep -c . || true)
    [ "${nlu:-0}" -le 5 ] || prob "$nlu lanes (cap 5)"
    dup=$(awk -F'\t' 'NF>=2{k=$2; if (k in o && o[k]!=$1) print k; o[k]=$1}' "$dr/scopes.txt" 2>/dev/null | head -3)
    [ -z "$dup" ] || prob "two lanes own the same path: $(echo $dup)"
    head -1 "$dr/CONTRACTS.md" 2>/dev/null | grep -q '^version:' || prob "CONTRACTS.md must start with version: 1"
    say "DRAFT: $nm milestone(s), $ntask task(s), ${nlu:-0} lane(s); baseline: $(head -1 "$dr/baseline.cmd" 2>/dev/null)"
    say "$(head -1 "$dr/PLAN.md" 2>/dev/null)"
    q=$(head -c 900 "$dr/QUESTIONS.md" 2>/dev/null); [ "$(echo $q)" = NONE ] && say "QUESTIONS: none" || { say "QUESTIONS:"; printf '%s\n' "$q" | head -5; }
    exit "$bad";;
  apply|go)
    ship=0; budget=600
    while [ $# -gt 0 ]; do case "$1" in --ship) ship=1; shift;; --budget) budget=$2; shift 2;; *) shift;; esac; done
    c=$(bash "$0" "$proj" check) || { printf '%s\n' "$c"; echo "PLAN STOP: fix the problems above (re-draft with --answers, or edit the draft files), then rerun"; exit 1; }
    mkdir -p "$crew/prompts" "$crew/milestones"
    cp "$dr/PLAN.md" "$crew/PLAN.md"; cp "$dr/SPEC.md" "$crew/SPEC.md"; cp "$dr/CONTRACTS.md" "$crew/CONTRACTS.md"; cp "$dr/ROSTER.md" "$crew/ROSTER.md"; cp "$dr/scopes.txt" "$crew/scopes.txt"; [ -n "$(tail -c1 "$crew/scopes.txt")" ] && echo >> "$crew/scopes.txt"  # a missing final newline hides the last scope from `read` loops
    cp "$dr/baseline.cmd" "$crew/baseline.cmd.draft"; cp "$dr"/prompts/* "$crew/prompts/" 2>/dev/null; cp "$dr"/milestones/m*.tasks "$crew/milestones/"
    printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n' > "$crew/TASKS.md"
    [ -f "$crew/BOARD.md" ] || : > "$crew/BOARD.md"
    { echo "approved: $(date +%F)"; [ "$ship" = 1 ] && echo "ship: yes"; echo "autonomy: auto"; echo "budget_minutes: $budget"; } >> "$crew/PLAN.md"
    bash "$here/crew-budget.sh" "$proj" set "$budget" >/dev/null 2>&1
    echo "PLAN APPLIED: $(echo "$c" | head -1)"
    if [ "$mode" = go ]; then
      bash "$here/crew-init.sh" "$proj" "$(head -1 "$dr/baseline.cmd")" --trust || exit 1
      bash "$here/crew-autopilot.sh" "$proj" --detach
    else echo "next: bash $here/crew-init.sh $proj \"$(head -1 "$dr/baseline.cmd")\" --trust && bash $here/crew-autopilot.sh $proj --detach"; fi;;
  *) sed -n 2,8p "$0"; exit 2;;
esac
