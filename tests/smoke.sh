#!/usr/bin/env bash
# Offline regression test: every crew script against a fake `devin`. No network, no real Devin, ~10 seconds.
#   bash tests/smoke.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; S="$here/../scripts"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
proj="$work/proj"; mkdir -p "$proj/.devin-crew" "$work/out"
export STUB_OUT="$work/out" STUB_BOARD="$proj/.devin-crew/BOARD.md" PATH="$here/stub:$PATH"
crew="$proj/.devin-crew"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1   [$2]"; fi; }

echo "--- lint"
if command -v shellcheck >/dev/null; then ok "shellcheck clean" "shellcheck -S warning $S/*.sh >/dev/null"; else echo "skip shellcheck (not installed)"; fi

echo "--- mail"
bash "$S/lane-msg.sh" "$proj" send api tests "one" >/dev/null
bash "$S/lane-msg.sh" "$proj" send api tests "two" >/dev/null
ok "pending counts 2 unread" '[ "$(bash $S/lane-msg.sh $proj pending)" = "tests not-started 2" ]'
r=$(bash "$S/lane-msg.sh" "$proj" read tests)
ok "read delivers both" 'printf "%s" "$r" | grep -q two && printf "%s" "$r" | grep -q one'
ok "second read is empty" '[ "$(bash $S/lane-msg.sh $proj read tests)" = "(no new mail)" ]'
bash "$S/lane-msg.sh" "$proj" send api tests "three" >/dev/null
ok "only new mail after cursor" '[ "$(bash $S/lane-msg.sh $proj read tests)" = "[api -> tests] three" ]'

echo "--- lane run / resume"
printf 'build the thing\n' > "$work/task.md"
printf 'x\tsrc/*\n' > /dev/null
out=$(bash "$S/devin-lane.sh" "$proj" api some-other-model "$work/task.md" 2>&1)
ok "lane finishes done" '[ "$(cat $crew/lanes/api.status)" = "done" ]'
ok "model coerced" 'grep -q "model=swe-2-flash-high" $STUB_OUT/args.log'
ok "bypass mode default" 'grep -q "perm=dangerous" $STUB_OUT/args.log'
ok "session id recorded" '[ "$(cat $crew/lanes/api.sid)" = "stub-session-1" ]'
ok "task and preamble in prompt" 'grep -q "build the thing" $STUB_OUT/prompts.log && grep -q "api" $STUB_OUT/prompts.log'
bash "$S/lane-msg.sh" "$proj" send tests api "hello api" >/dev/null
bash "$S/devin-lane.sh" "$proj" api - - >/dev/null 2>&1
ok "wake resumes same session" 'grep -q "resume=stub-session-1" $STUB_OUT/args.log'
ok "wake prompt carries mail" 'tail -20 $STUB_OUT/prompts.log | grep -q "hello api"'
ok "log counter counts both runs" '[ "$(ls $crew/logs | grep -c "^api\.[0-9]")" = "2" ]'
STUB_EXIT=3 bash "$S/devin-lane.sh" "$proj" bad - "$work/task.md" >/dev/null 2>&1
bash "$S/devin-lane.sh" "$proj" bad2 - "$work/task.md" >/dev/null 2>&1
STUB_EXIT=3 bash "$S/devin-lane.sh" "$proj" bad2 - "$work/task.md" >/dev/null 2>&1
ok "nonzero exit -> failed(n)" '[ "$(cat $crew/lanes/bad2.status)" = "failed(3)" ]'
ok "events log has elapsed" 'grep -q "exit status=done session=stub-session-1 elapsed=[0-9]* nudges=0" $crew/events.log'

echo "--- doctor"
d=$(bash "$S/crew-doctor.sh" "$proj" 2>&1); rc=$?
ok "doctor ready on a healthy setup" '[ "$rc" = 0 ] && printf "%s" "$d" | grep -q "doctor: ready" && printf "%s" "$d" | grep -q "model available: swe-2-flash-high"'
d=$(STUB_AUTH=out bash "$S/crew-doctor.sh" "$proj" 2>&1); rc=$?
ok "doctor fails when logged out, with fix" '[ "$rc" = 1 ] && printf "%s" "$d" | grep -q "FAIL devin not logged in.*devin auth login"'
d=$(STUB_NO_MODEL=1 bash "$S/crew-doctor.sh" "$proj" 2>&1); rc=$?
ok "doctor fails when model missing" '[ "$rc" = 1 ] && printf "%s" "$d" | grep -q "FAIL model swe-2-flash-high"'
d=$(bash "$S/crew-doctor.sh" "$work/nope" 2>&1); rc=$?
ok "doctor fails on missing folder" '[ "$rc" = 1 ]'
ok "doctor flags non-git project" 'bash "$S/crew-doctor.sh" "$proj" 2>&1 | grep -q "WARN not a git repo"'

echo "--- resume"
rp="$work/rproj"; mkdir -p "$rp/.devin-crew/lanes"; rc_="$rp/.devin-crew"
r=$(bash "$S/crew-resume.sh" "$work/nope-empty" 2>&1 || true)
mkdir -p "$work/empty"; r=$(bash "$S/crew-resume.sh" "$work/empty")
ok "no crew: says start fresh" 'printf "%s" "$r" | grep -q "nothing to resume"'
cat > "$rc_/TASKS.md" <<'T'
| id | lane | scope | depends | acceptance | status |
|----|------|-------|---------|------------|--------|
| r1 | a | a/* | - | true | review |
| r2 | b | b/* | - | true | failed |
| r3 | c | c/* | r1 | true | open |
T
echo running > "$rc_/lanes/a.status"; echo 999999 > "$rc_/lanes/a.pid"; date +%s > "$rc_/lanes/a.started"
r=$(bash "$S/crew-resume.sh" "$rp")
ok "missing PLAN.md is called out" 'printf "%s" "$r" | grep -q "NO PLAN.md"'
ok "dead process detected" 'printf "%s" "$r" | grep -q "process is gone"'
ok "review tasks -> verify" 'printf "%s" "$r" | grep -q "1 task(s) in review"'
ok "failed tasks -> diagnose" 'printf "%s" "$r" | grep -q "1 failed task(s)"'
printf 'goal: demo\napproved: 2026-11-10\n' > "$rc_/PLAN.md"
r=$(bash "$S/crew-resume.sh" "$rp")
ok "plan is printed" 'printf "%s" "$r" | grep -q "goal: demo"'
printf '| id | lane | scope | depends | acceptance | status |\n|--|--|--|--|--|--|\n| r1 | a | a/* | - | true | done |\n' > "$rc_/TASKS.md"
echo done > "$rc_/lanes/a.status"; rm -f "$rc_/lanes/a.pid"
r=$(bash "$S/crew-resume.sh" "$rp")
ok "all done -> QA next" 'printf "%s" "$r" | grep -q "All tasks done: run milestone QA"'

echo "--- qa history"
hp="$work/hproj"; mkdir -p "$hp/.devin-crew"
r=$(bash "$S/crew-qa-history.sh" "$hp" show)
ok "empty history says so" 'printf "%s" "$r" | grep -q "no findings recorded"'
ok "bad class rejected" '! bash $S/crew-qa-history.sh $hp add M1 api nonsense HIGH "x" 2>/dev/null'
ok "bad severity rejected" '! bash $S/crew-qa-history.sh $hp add M1 api stub URGENT "x" 2>/dev/null'
bash "$S/crew-qa-history.sh" "$hp" add M1 api error-path MED "no timeout handling" >/dev/null
ok "single MED finding: no watch yet" '[ -z "$(bash $S/crew-qa-history.sh $hp watch)" ]'
bash "$S/crew-qa-history.sh" "$hp" add M1 tests weak-test HIGH "assertion-free test" >/dev/null
ok "a HIGH puts its class on the watch list" 'bash $S/crew-qa-history.sh $hp watch | grep -q "class weak-test: seen 1x (HIGH"'
bash "$S/crew-qa-history.sh" "$hp" add M2 api error-path MED "bad input crashes" >/dev/null
w=$(bash "$S/crew-qa-history.sh" "$hp" watch)
ok "repeat class and repeat lane watched" 'printf "%s" "$w" | grep -q "class error-path: seen 2x" && printf "%s" "$w" | grep -q "lane api: 2 findings"'
printf '2026-11-10 10:00:00 tests NUDGE 1/2 on session x after: STALLED\n' > "$hp/.devin-crew/events.log"
ok "rescued lane watched from events.log" 'bash $S/crew-qa-history.sh $hp watch | grep -q "lane tests: needed rescue 1x"'
ok "show summarizes counts" 'bash $S/crew-qa-history.sh $hp show | grep -q "3 finding(s) over 2 milestone(s)"'

echo "--- symlinked paths"
wp="$work/wproj"; mkdir -p "$wp"; git -C "$wp" init -q; git -C "$wp" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
ok "worktree add works under a symlinked temp path" 'bash $S/crew-worktree.sh $wp add w1 >/dev/null 2>&1 && [ -d "$(cd $wp && pwd -P)/.devin-crew/wt/w1" ]'
bash "$S/crew-worktree.sh" "$wp" remove w1 >/dev/null 2>&1

echo "--- budget"
bp="$work/bproj"; mkdir -p "$bp/.devin-crew/lanes"; bc="$bp/.devin-crew"
ok "no budget: fine" 'bash $S/crew-budget.sh $bp check | grep -q "none set"'
bash "$S/crew-budget.sh" "$bp" set 10 >/dev/null
printf '2026-11-10 10:00:00 api exit status=done session=x elapsed=60 nudges=0\n' > "$bc/events.log"
ok "under 80%: exit 0" 'bash $S/crew-budget.sh $bp check >/dev/null; [ $? -eq 0 ]'
printf '2026-11-10 10:00:00 api exit status=done session=x elapsed=480 nudges=0\n' > "$bc/events.log"
ok "at 80%: warns, exit 1" 'bash $S/crew-budget.sh $bp check >/dev/null; [ $? -eq 1 ]'
printf '2026-11-10 10:00:00 api exit status=done session=x elapsed=400 nudges=0\n2026-11-10 10:10:00 ui exit status=done session=y elapsed=300 nudges=0\n' > "$bc/events.log"
ok "over budget: exit 2 and says so" 'r=$(bash $S/crew-budget.sh $bp check); [ $? -eq 2 ] && printf "%s" "$r" | grep -q "BUDGET EXCEEDED"'
calls_before=$(cat "$STUB_OUT/count")
bash "$S/devin-lane.sh" "$bp" api - "$work/task.md" >/dev/null 2>&1; rc=$?
ok "lane launch refused when exceeded" '[ "$rc" = 4 ] && [ "$(cat $STUB_OUT/count)" = "$calls_before" ] && [ ! -f $bc/lanes/api.status ]'
CREW_BUDGET_OVERRIDE=1 bash "$S/devin-lane.sh" "$bp" api swe-2-flash-high "$work/task.md" >/dev/null 2>&1
ok "override lets it run" '[ "$(cat $bc/lanes/api.status)" = "done" ]'
bash "$S/lane-msg.sh" "$bp" send ui api "hi" >/dev/null
r=$(CREW_ROUTER_MAX_SECS=30 bash "$S/crew-router.sh" "$bp" 1)
ok "router will not wake lanes over budget" 'printf "%s" "$r" | grep -q "QUIESCENT-WITH-STUCK-MAIL api(budget-exceeded,1)"'
bash "$S/crew-budget.sh" "$bp" set none >/dev/null
ok "set none removes the cap" 'bash $S/crew-budget.sh $bp check | grep -q "none set"'

echo "--- dry run (--print)"
dp="$work/dproj"; mkdir -p "$dp"; git -C "$dp" init -q
calls=$(cat "$STUB_OUT/count")
d=$(CREW_ROLE=tests CREW_GIT=commit bash "$S/devin-lane.sh" --print "$dp" dl swe-2-flash-high "$work/task.md" 2>&1)
ok "print shows rights, role and task" 'printf "%s" "$d" | grep -q "DRY RUN" && printf "%s" "$d" | grep -q "NEW session" && printf "%s" "$d" | grep -q "git rights: commit" && printf "%s" "$d" | grep -q "build the thing"'
ok "print launches nothing and writes nothing" '[ "$(cat $STUB_OUT/count)" = "$calls" ] && [ ! -e "$dp/.devin-crew" ]'
mkdir -p "$dp/.devin-crew/lanes"; echo "stub-session-9" > "$dp/.devin-crew/lanes/dl.sid"
bash "$S/lane-msg.sh" "$dp" send x dl "peek test" >/dev/null
d=$(bash "$S/devin-lane.sh" --print "$dp" dl - - 2>&1)
ok "print of a wake shows the unread mail count" 'printf "%s" "$d" | grep -q "resume of session stub-session-9" && printf "%s" "$d" | grep -q "1 unread message"'
ok "print does not consume mail" '[ "$(bash $S/lane-msg.sh $dp pending)" = "dl not-started 1" ]'
ok "print writes no events" '[ ! -e "$dp/.devin-crew/events.log" ]'

echo "--- git rights"
gproj="$work/gproj"; mkdir -p "$gproj"; git -C "$gproj" init -q
last_prompt() { awk '/^=== call/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$STUB_OUT/prompts.log"; }
bash "$S/devin-lane.sh" "$gproj" g0 - "$work/task.md" >/dev/null 2>&1
ok "default: no git writes" 'last_prompt | grep -q "may not run any git write command"'
CREW_GIT=commit bash "$S/devin-lane.sh" "$gproj" g1 - "$work/task.md" >/dev/null 2>&1
ok "commit: scoped add, no push" 'last_prompt | grep -q "You MAY commit" && last_prompt | grep -q "Do not push" && last_prompt | grep -q "\[crew:g1\]"'
CREW_GIT=push CREW_GIT_TARGET="origin main" bash "$S/devin-lane.sh" "$gproj" g2 - "$work/task.md" >/dev/null 2>&1
ok "push: exact target, never force" 'last_prompt | grep -q "git push origin main" && last_prompt | grep -q "Never force-push"'
CREW_GIT=push bash "$S/devin-lane.sh" "$gproj" g3 - "$work/task.md" >/dev/null 2>&1
ok "push without target falls back to commit" 'last_prompt | grep -q "Do not push"'
CREW_GIT=push CREW_GIT_TARGET="origin main; rm -rf /" bash "$S/devin-lane.sh" "$gproj" g4 - "$work/task.md" >/dev/null 2>&1
ok "injected target rejected" '! last_prompt | grep -q "rm -rf" && last_prompt | grep -q "Do not push"'
CREW_GIT=commit bash "$S/devin-lane.sh" "$proj" g5 - "$work/task.md" >/dev/null 2>&1
ok "non-git project: no git rights" 'last_prompt | grep -q "may not run any git write command"'
mkdir -p "$gproj/.devin-crew/lanes"; echo "$work/proj" > "$gproj/.devin-crew/lanes/g6.workdir"
CREW_GIT=commit bash "$S/devin-lane.sh" "$gproj" g6 - "$work/task.md" >/dev/null 2>&1
ok "worktree lane: git rights refused" 'last_prompt | grep -q "may not run any git write command"'

echo "--- router"
bash "$S/lane-msg.sh" "$proj" send tests api "wake me" >/dev/null
r=$(CREW_ROUTER_MAX_SECS=60 bash "$S/crew-router.sh" "$proj" 1)
ok "router wakes idle lane then goes quiet" '[ "$r" = "QUIESCENT" ] && tail -30 $STUB_OUT/prompts.log | grep -q "wake me"'
bash "$S/lane-msg.sh" "$proj" send api orchestrator "need a decision" >/dev/null
r=$(CREW_ROUTER_MAX_SECS=60 bash "$S/crew-router.sh" "$proj" 1)
ok "router stops for orchestrator mail" '[ "$r" = "ORCHESTRATOR-MAIL 1" ]'
bash "$S/lane-msg.sh" "$proj" read orchestrator >/dev/null
echo "failed(timeout)" > "$crew/lanes/bad.status"
bash "$S/lane-msg.sh" "$proj" send api bad "you there" >/dev/null
r=$(CREW_ROUTER_MAX_SECS=60 bash "$S/crew-router.sh" "$proj" 1)
ok "router flags unwakeable lane" 'printf "%s" "$r" | grep -q "^QUIESCENT-WITH-STUCK-MAIL bad(failed(timeout),1)"'

echo "--- task status"
cat > "$crew/TASKS.md" <<'T'
| id | lane | scope | depends | acceptance | status |
|----|------|-------|---------|------------|--------|
| s1 | api  | src/* | -  | true | open |
| s2 | bad2 | x/* | s1 | true | open |
| s3 | docs | d/* | s1,s2 | true | open |
T
ok "next: only the unblocked task" '[ "$(bash $S/crew-tasks.sh $proj next)" = "s1 api" ]'
bash "$S/devin-lane.sh" "$proj" api - "$work/task.md" >/dev/null 2>&1
ok "lane exit ok -> task review" 'grep -q "| s1 .*| review |" $crew/TASKS.md'
bash "$S/crew-tasks.sh" "$proj" set s1 done
ok "next: s2 unblocked after s1 done" '[ "$(bash $S/crew-tasks.sh $proj next)" = "s2 bad2" ]'
STUB_EXIT=3 bash "$S/devin-lane.sh" "$proj" bad2 - "$work/task.md" >/dev/null 2>&1
ok "lane exit nonzero -> task failed" 'grep -q "| s2 .*| failed |" $crew/TASKS.md'
ok "set leaves other rows alone" 'grep -q "| s3 .*| open |" $crew/TASKS.md && grep -q "| s1 .*| done |" $crew/TASKS.md'

echo "--- verify"
cat > "$crew/TASKS.md" <<'T'
| id | lane | scope | depends | acceptance | status |
|----|------|-------|---------|------------|--------|
| t1 | api  | src/* | -  | true | done |
| t2 | tests| tests/* | t1 | echo boom; false | done |
| t3 | api  | src/* | -  | - | done |
| t4 | ghost | x | - | false | open |
T
printf 'version: 2\n' > "$crew/CONTRACTS.md"
printf 'DONE api: files changed: a | verified: x -> ok | contracts: v1 | open issues: none\n' >> "$crew/BOARD.md"
echo done > "$crew/lanes/tests.status"
printf 'DONE tests: files changed: b | verified: y -> ok | contracts: v2 | open issues: none\n' >> "$crew/BOARD.md"
v=$(bash "$S/crew-verify.sh" "$proj"); rc=$?
ok "verify exits 1 on problems" '[ "$rc" = 1 ]'
ok "passing acceptance reported" 'printf "%s" "$v" | grep -q "^PASS t1 api"'
ok "failing acceptance shows output" 'printf "%s" "$v" | grep -q "^FAIL t2 tests (exit 1)" && printf "%s" "$v" | grep -q boom'
ok "not-started lane skipped" 'printf "%s" "$v" | grep -q "^SKIP t4 ghost: lane not started"'
ok "verify writes status back" 'grep -q "| t2 .*| failed |" $crew/TASKS.md && grep -q "| t1 .*| done |" $crew/TASKS.md'
ok "dash acceptance skipped" 'printf "%s" "$v" | grep -q "^SKIP t3 api"'
ok "stale contract caught" 'printf "%s" "$v" | grep -q "^STALE-CONTRACT api: built against v1, CONTRACTS.md is v2"'
ok "fresh contract ok" 'printf "%s" "$v" | grep -q "^CONTRACT-OK tests: v2"'
printf '| t9 | api | s | - | sleep 30 | done |\n' > "$crew/TASKS.md"
v=$(CREW_VERIFY_SECS=2 bash "$S/crew-verify.sh" "$proj" api 2>&1)
ok "acceptance timeout enforced" 'printf "%s" "$v" | grep -q "^TIMEOUT t9 api"'

echo "--- report"
rep=$(bash "$S/crew-report.sh" "$proj")
ok "report lists lanes with counts" 'printf "%s" "$rep" | grep -Eq "^api +1 +[0-9]+" && printf "%s" "$rep" | grep -q "failed(3)"'

echo "--- guard"
mkdir -p "$proj/src" "$proj/docs"; printf 'api\tsrc/*\n' > "$crew/scopes.txt"
bash "$S/crew-guard.sh" "$proj" snapshot >/dev/null 2>&1
echo hi > "$proj/src/a.txt"; echo hi > "$proj/docs/b.txt"
g=$(bash "$S/crew-guard.sh" "$proj" check 2>&1)
ok "scope check flags out-of-scope file" 'printf "%s" "$g" | grep -q "OUTSIDE SCOPE.*docs/b.txt"'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
