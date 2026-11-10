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
