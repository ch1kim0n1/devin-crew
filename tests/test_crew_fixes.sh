#!/usr/bin/env bash
# Regression tests for devin-crew bugs 1-4. usage: bash test_crew_fixes.sh <skill_dir>
set -u
SK=$(cd "$1" && pwd); T=$(mktemp -d); fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
status_of() { awk -F'|' -v id="$2" '/^\| t/{gsub(/ /,"",$2);gsub(/ /,"",$(NF-1)); if($2==id) print $(NF-1)}' "$1/.devin-crew/TASKS.md"; }

mkproj() { # mkproj <dir>: a crew with lane L owning t1,t2 (t2 depends t1) and lane M owning t3
  local p=$1; mkdir -p "$p/.devin-crew"/{lanes,logs,prompts,conduct}
  cat > "$p/.devin-crew/TASKS.md" <<'EOF'
| id | lane | scope | depends | acceptance | status |
|---|---|---|---|---|---|
| t1 | L | a/** | - | true | open |
| t2 | L | b/** | t1 | true | open |
| t3 | M | c/** | - | true | open |
EOF
  echo "brief t1" > "$p/.devin-crew/prompts/t1.md"
}

# ---- bug 1: launching t1 must not touch t2 (same lane)
P=$T/p1; mkproj "$P"; mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/devin"; chmod +x "$T/bin/devin"
PATH="$T/bin:$PATH" CREW_BUDGET_OVERRIDE=1 bash "$SK/scripts/devin-lane.sh" "$P" L - "$P/.devin-crew/prompts/t1.md" >/dev/null 2>&1
[ "$(status_of "$P" t1)" = review ] && ok "bug1: t1 -> review after clean exit" || bad "bug1: t1 expected review, got $(status_of "$P" t1)"
[ "$(status_of "$P" t2)" = open ]   && ok "bug1: t2 stays open (never ran)"   || bad "bug1: t2 expected open, got $(status_of "$P" t2)"
[ "$(status_of "$P" t3)" = open ]   && ok "bug1: other lane untouched"        || bad "bug1: t3 changed"

# ---- bug 1b: a fix brief (no task id) only revives tasks already in review/failed, never open ones
P=$T/p1b; mkproj "$P"; echo "fix" > "$P/.devin-crew/prompts/L-fix-1.md"
sed -i '' 's/| t1 | L | a\/\*\* | - | true | open |/| t1 | L | a\/** | - | true | review |/' "$P/.devin-crew/TASKS.md"
PATH="$T/bin:$PATH" CREW_BUDGET_OVERRIDE=1 bash "$SK/scripts/devin-lane.sh" "$P" L - "$P/.devin-crew/prompts/L-fix-1.md" >/dev/null 2>&1
[ "$(status_of "$P" t2)" = open ] && ok "bug1b: fix brief leaves open t2 alone" || bad "bug1b: t2 expected open, got $(status_of "$P" t2)"

# ---- bug 2: classifier must ignore prose, still catch real errors
mklog() { P=$T/$1; mkproj "$P"; printf '%s\n' "$2" > "$P/.devin-crew/logs/L.1.log"; bash "$SK/scripts/crew-observe.sh" "$P" L --error | head -1; }
r=$(mklog c1 "Not verified: the workflow has not run because Actions is billing-blocked and the request timed out once; process killed by me.")
[ -z "$r" ] && ok "bug2: prose with billing/timed out/killed is not an error" || bad "bug2: prose misclassified as $r"
r=$(mklog c2 'Error: Agent error: Your weekly usage quota has been exhausted. Visit x: {
  "cognition.ai/errorKind": "resource_exhausted"
}')
[ "$r" = RATE_OR_QUOTA ] && ok "bug2: real quota error still caught" || bad "bug2: real quota error got '$r'"
r=$(mklog c3 'Error: Agent error: Reached free model rate limit. Your limit will reset in 3 minutes (at 00:38 UTC).: {')
[ "$r" = RATE_OR_QUOTA ] && ok "bug2: real rate-limit error still caught" || bad "bug2: rate limit got '$r'"

# ---- bugs 3+4: one command recovers a failed lane and clears its sticky model
P=$T/p3; mkproj "$P"; C=$P/.devin-crew
echo "failed(1)" > $C/lanes/L.status; echo claude-sonnet-5-5-high > $C/lanes/L.model; echo sess > $C/lanes/L.sid
echo EXIT-1 > $C/lanes/L.needs-user; echo brain > $C/conduct/L.state; echo why > $C/conduct/L.brain; touch $C/conduct/L.reported
sed -i '' 's/| t1 | L | a\/\*\* | - | true | open |/| t1 | L | a\/** | - | true | failed |/' $C/TASKS.md
if [ -f "$SK/scripts/crew-lane-reset.sh" ]; then
  bash "$SK/scripts/crew-lane-reset.sh" "$P" L >/dev/null 2>&1
  [ ! -f $C/lanes/L.model ] && ok "bug4: sticky model cleared" || bad "bug4: model file still there"
  [ ! -f $C/lanes/L.sid ] && ls $C/lanes | grep -q '^L.sid\.' && ok "bug4: session moved aside, not deleted" || bad "bug4: session not moved aside"
  [ ! -f $C/lanes/L.needs-user ] && ok "bug3: needs-user cleared" || bad "bug3: needs-user still there"
  [ "$(cat $C/conduct/L.state)" = idle ] && ok "bug3: conductor state idle" || bad "bug3: conductor state $(cat $C/conduct/L.state)"
  [ "$(status_of "$P" t1)" = open ] && ok "bug3: failed task reopened" || bad "bug3: t1 is $(status_of "$P" t1)"
  [ "$(status_of "$P" t3)" = open ] && ok "bug3: other lane untouched" || bad "bug3: t3 changed"
else
  bad "bug3/4: crew-lane-reset.sh missing"
fi
bash "$SK/scripts/crew-conduct.sh" "$P" --reset L 2>&1 | grep -q "crew-lane-reset" && ok "bug3: --reset output points to crew-lane-reset.sh" || bad "bug3: --reset does not say it only resets conductor state"

# ---- bug 8: scopes.txt without a final newline must not hide its last line
P=$T/p8; mkdir -p "$P/.devin-crew"; printf 'A\ta/**\nB\ta/**' > "$P/.devin-crew/scopes.txt"
bash "$SK/scripts/crew-guard.sh" "$P" scopes 2>&1 | grep -q "SCOPE OVERLAP: A" && ok "bug8: last scope line read without a final newline" || bad "bug8: last scope line ignored"

rm -rf "$T"; [ $fail -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
