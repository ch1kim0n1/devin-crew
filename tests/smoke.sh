#!/usr/bin/env bash
# Offline regression test: every crew script against a fake `devin`. No network, no real Devin, ~10 seconds.
#   bash tests/smoke.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; S="$here/../scripts"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
proj="$work/proj"; mkdir -p "$proj/.devin-crew" "$work/out"
export STUB_OUT="$work/out" STUB_BOARD="$proj/.devin-crew/BOARD.md" PATH="$here/stub:$PATH"
crew="$proj/.devin-crew"
export CREW_NOTIFY=off CREW_LEDGER="$work/ledger.tsv" DEVIN_SESSIONS_DB="$work/sessions.db"   # never touch the real ledger or Devin's store
sqlite3 "$DEVIN_SESSIONS_DB" "create table sessions(id text, metadata text); create table message_nodes(session_id text, node_id int, chat_message text, metadata text); create table tool_call_state(session_id text);
insert into sessions values('stub-session-1','{\"total_acu_cost\":0.5}');
insert into message_nodes values('stub-session-1',1,'{\"role\":\"assistant\",\"content\":\"aaaaaaaaaaaaaaaaaaaa\"}','{\"num_tokens_preceding\":1000}');
insert into message_nodes values('stub-session-1',2,'{\"role\":\"assistant\",\"content\":\"bbbbbbbbbbbbbbbbbbbb\"}','{\"num_tokens_preceding\":3000}');
insert into tool_call_state values('stub-session-1'); insert into tool_call_state values('stub-session-1');"
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
CREW_MODEL=my-other-model bash "$S/devin-lane.sh" "$proj" mdl - "$work/task.md" >/dev/null 2>&1
ok "CREW_MODEL changes the lane model" 'grep -q "model=my-other-model" $STUB_OUT/args.log && [ "$(cat $crew/lanes/mdl.model)" = "my-other-model" ]'
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

echo "--- devin errors go to the user"
out=$(STUB_EXIT=1 STUB_OUTPUT="Error: 429 usage limit reached" bash "$S/devin-lane.sh" "$proj" lim - "$work/task.md" 2>&1)
ok "limit error: lane failed, class recorded" '[ "$(head -1 $crew/lanes/lim.needs-user)" = "RATE_OR_QUOTA" ] && grep -q "status: failed(1)" $crew/lanes/lim.needs-user'
ok "limit error: output tells orchestrator to report" 'printf "%s" "$out" | grep -q "NEEDS-USER lane=lim class=RATE_OR_QUOTA" && printf "%s" "$out" | grep -q "user fix: .*limit" && printf "%s" "$out" | grep -q "CREW_RETRY_OK=1"'
c0=$(cat "$STUB_OUT/count")
bash "$S/devin-lane.sh" "$proj" lim - - >/dev/null 2>&1; rc=$?
ok "relaunch refused (exit 5), devin not called" '[ "$rc" = 5 ] && [ "$(cat $STUB_OUT/count)" = "$c0" ]'
ok "--print shows the refusal" 'bash "$S/devin-lane.sh" --print "$proj" lim - - 2>&1 | grep -q "WOULD REFUSE (awaiting user"'
ok "status marks it" 'bash "$S/crew-status.sh" "$proj" | grep -q "NEEDS-USER(RATE_OR_QUOTA)"'
ok "resume says tell the user first" 'bash "$S/crew-resume.sh" "$proj" | grep -q "Lane lim STOPPED on a Devin error (RATE_OR_QUOTA)"'
bash "$S/lane-msg.sh" "$proj" send tests lim "mail for lim" >/dev/null
r=$(CREW_ROUTER_MAX_SECS=30 bash "$S/crew-router.sh" "$proj" 1)
ok "router does not wake it, lists it as stuck" 'printf "%s" "$r" | grep -q "QUIESCENT-WITH-STUCK-MAIL.*lim(needs-user:RATE_OR_QUOTA"'
CREW_RETRY_OK=1 bash "$S/devin-lane.sh" "$proj" lim - - >/dev/null 2>&1
ok "CREW_RETRY_OK=1 relaunches and clears the flag" '[ "$(cat $STUB_OUT/count)" = "$((c0 + 1))" ] && [ ! -f $crew/lanes/lim.needs-user ] && [ "$(cat $crew/lanes/lim.status)" = "done" ] && grep -q "RETRY approved by the user after RATE_OR_QUOTA" $crew/events.log'
STUB_EXIT=3 bash "$S/devin-lane.sh" "$proj" ex - "$work/task.md" >/dev/null 2>&1
ok "unexplained nonzero exit also goes to the user" '[ "$(head -1 $crew/lanes/ex.needs-user)" = "EXIT-3" ]'
STUB_EXIT=1 STUB_OUTPUT="prompt is too long for the context window" bash "$S/devin-lane.sh" "$proj" ctx - "$work/task.md" >/dev/null 2>&1
ok "context-too-long stays with the orchestrator" '[ ! -f $crew/lanes/ctx.needs-user ] && [ "$(cat $crew/lanes/ctx.status)" = "failed(1)" ]'

echo "--- usage ledger and analytics"
led() { awk -F'\t' "$1 {f=1} END{exit !f}" "$CREW_LEDGER"; }
ok "ledger gets a turn row with tokens" 'led "\$1==\"turn\" && \$4==\"api\" && \$5==\"done\" && \$10==3000 && \$11==4000 && \$12==10 && \$13==2 && \$14==2 && \$15==0.5"'
ok "limit stop is in the ledger with its class" 'led "\$1==\"turn\" && \$4==\"lim\" && \$5==\"failed(1)\" && \$9==\"RATE_OR_QUOTA\""'
bash "$S/crew-qa-history.sh" "$proj" add m1 api stub HIGH "x" >/dev/null
ok "qa finding reaches the ledger" 'led "\$1==\"qa\" && \$4==\"api\" && \$5==\"stub\" && \$6==\"HIGH\""'
a=$(bash "$S/crew-analytics.sh")
ok "text summary has usage, tokens, tasks, projects, fun" 'printf "%s" "$a" | grep -q "lane turns" && printf "%s" "$a" | grep -q "tokens:" && printf "%s" "$a" | grep -q "tasks:" && printf "%s" "$a" | grep -q "projects:" && printf "%s" "$a" | grep -q "Marathoner"'
ok "tokens counted once per session, not per turn" 'printf "%s" "$a" | grep -Eq "~4k input"'
v=$(bash "$S/crew-analytics.sh" viz "$work/report.html")
ok "viz writes a self-contained html" 'printf "%s" "$v" | grep -q "^report: " && grep -q "<svg" $work/report.html && ! grep -Eq "src=.http|href=.http" $work/report.html'
ok "empty ledger is handled" 'CREW_LEDGER=$work/none.tsv bash $S/crew-analytics.sh | grep -q "^no usage recorded yet"'

echo "--- real Devin error wording (tests/fixtures/real-errors.tsv: lines seen in real Devin logs or its binary)"
mkdir -p "$crew/logs"
while IFS=$'\t' read -r want text; do
  printf '%s\n' "$text" > "$crew/logs/fx.1.log"
  got=$(bash "$S/crew-observe.sh" "$proj" fx --error | head -1)
  ok "classified $want: ${text:0:40}" '[ "$got" = "$want" ]'
done < "$here/fixtures/real-errors.tsv"
rm -f "$crew/logs/fx.1.log"
printf 'Error: Agent error: Reached request rate limit. Your limit will reset in 2 minutes (at 00:53 UTC).\n' > "$crew/logs/fx.1.log"
rs=$(bash "$S/crew-observe.sh" "$proj" fx --reset); nw=$(date +%s)
ok "reset time parsed from 'reset in 2 minutes'" '[ "$rs" -ge $((nw + 118)) ] && [ "$rs" -le $((nw + 130)) ]'
printf 'something unrelated\n' > "$crew/logs/fx.1.log"
ok "no reset time -> empty" '[ -z "$(bash $S/crew-observe.sh $proj fx --reset)" ]'
rm -f "$crew/logs/fx.1.log"

echo "--- retry at an approved time"
STUB_EXIT=1 STUB_OUTPUT="Reached request rate limit. Your limit will reset in 2 seconds." bash "$S/devin-lane.sh" "$proj" rt - "$work/task.md" >/dev/null 2>&1
ok "retry-at refuses a lane that is not waiting" '! bash $S/crew-retry-at.sh $proj api +1 >/dev/null 2>&1'
c1=$(cat "$STUB_OUT/count")
( bash "$S/crew-retry-at.sh" "$proj" rt auto >"$work/retry.out" 2>&1 & ); sleep 1
ok "retry scheduled and visible in status" 'grep -q "scheduled in" $work/retry.out && bash $S/crew-status.sh $proj | grep -q "RETRY-AT="'
sleep 9
ok "retry ran after the wait, with approval, resuming the session" '[ "$(cat $STUB_OUT/count)" = "$((c1 + 1))" ] && [ ! -f $crew/lanes/rt.needs-user ] && [ ! -f $crew/lanes/rt.retry-at ] && tail -5 $STUB_OUT/prompts.log | grep -q "cut off by a Devin error"'

echo "--- ledger hint"
h=$(bash "$S/crew-analytics.sh" hint)
ok "hint summarizes earlier crews" 'printf "%s" "$h" | grep -q "^history: 1 earlier crew" && printf "%s" "$h" | grep -q "first-try rate"'
ok "hint is silent without history" '[ -z "$(CREW_LEDGER=$work/none.tsv bash $S/crew-analytics.sh hint)" ]'

echo "--- run state stays out of commits"
gp="$work/gproj"; mkdir -p "$gp/.devin-crew"; git -C "$gp" init -q
bash "$S/crew-guard.sh" "$gp" lock >/dev/null 2>&1; bash "$S/crew-guard.sh" "$gp" unlock >/dev/null; bash "$S/crew-guard.sh" "$gp" lock >/dev/null 2>&1
ok "lock adds .devin-crew/ to .git/info/exclude once" '[ "$(grep -cxF ".devin-crew/" "$gp/.git/info/exclude")" = 1 ] && [ -z "$(git -C "$gp" status --porcelain)" ]'

echo "--- launch/wait/notify (agents without a background tool, e.g. Codex)"
cw="$work/cw"; mkdir -p "$cw/.devin-crew"
r=$(bash "$S/crew-launch.sh" "$cw" lane wl - "$work/task.md")
ok "launch returns at once with pid and log" 'printf "%s" "$r" | grep -q "^launched lane wl pid [0-9]"'
w=$(bash "$S/crew-wait.sh" "$cw" 30); rc=$?
ok "wait reports the lane exit once" '[ "$rc" = 0 ] && printf "%s" "$w" | grep -q "^LANE-EXIT wl done$"'
w=$(bash "$S/crew-wait.sh" "$cw" 5); rc=$?
ok "second wait: already reported -> NOTHING-RUNNING (exit 4)" '[ "$rc" = 4 ] && [ "$w" = "NOTHING-RUNNING" ]'
STUB_SLEEP=7 bash "$S/crew-launch.sh" "$cw" lane slow - "$work/task.md" >/dev/null
w=$(bash "$S/crew-wait.sh" "$cw" 2); rc=$?
ok "wait is bounded: timeout names the running lane (exit 3)" '[ "$rc" = 3 ] && printf "%s" "$w" | grep -q "^WAIT-TIMEOUT after 2s; running: slow"'
w=$(bash "$S/crew-wait.sh" "$cw" 40)
ok "later wait sees the exit" 'printf "%s" "$w" | grep -q "^LANE-EXIT slow done$"'
STUB_EXIT=1 STUB_OUTPUT="Reached request rate limit. Your limit will reset in 2 minutes." bash "$S/crew-launch.sh" "$cw" lane lim2 - "$work/task.md" >/dev/null
w=$(bash "$S/crew-wait.sh" "$cw" 40)
ok "wait surfaces NEEDS-USER with the class" 'printf "%s" "$w" | grep -q "^LANE-EXIT lim2 failed(1)$" && printf "%s" "$w" | grep -q "^NEEDS-USER lim2 RATE_OR_QUOTA$"'
bash "$S/crew-launch.sh" "$cw" lane lim2 - - >/dev/null 2>&1; rc=$?
ok "launch refuses a lane waiting on the user (exit 5)" '[ "$rc" = 5 ]'
bash "$S/crew-launch.sh" "$cw" router 1 >/dev/null
w=$(bash "$S/crew-wait.sh" "$cw" 40)
ok "wait reports the router's final line" 'printf "%s" "$w" | grep -q "^ROUTER QUIESCENT"'
ok "notify never fails" 'bash $S/crew-notify.sh "test message" >/dev/null 2>&1'

echo "--- codex packaging"
ok "SKILL.md frontmatter has name and description" 'head -5 "$here/../SKILL.md" | grep -q "^name: devin-crew" && head -5 "$here/../SKILL.md" | grep -q "^description: "'
ok "codex metadata and notes exist, SKILL.md points at them" '[ -f "$here/../agents/openai.yaml" ] && [ -f "$here/../reference/codex.md" ] && grep -q "reference/codex.md" "$here/../SKILL.md"'
fh="$work/fakehome"; mkdir -p "$fh/.claude/skills/devin-crew"; git -C "$fh/.claude/skills/devin-crew" init -q
HOME="$fh" bash "$here/../install.sh" --codex >/dev/null 2>&1
ok "install.sh --codex links the Claude install into ~/.codex/skills" '[ -L "$fh/.codex/skills/devin-crew" ]'

echo "--- devin as manager"
ok "devin.md exists and SKILL.md points at it" '[ -f "$here/../reference/devin.md" ] && grep -q "reference/devin.md" "$here/../SKILL.md"'
ok "lanes are told they are workers" 'grep -q "You are a worker lane" "$here/../templates/preamble.md"'
fh2="$work/fakehome2"; mkdir -p "$fh2/.claude/skills/devin-crew"; git -C "$fh2/.claude/skills/devin-crew" init -q
ok "install.sh --devin recognizes an existing Claude install" 'HOME="$fh2" bash "$here/../install.sh" --devin 2>&1 | grep -q "Nothing to install"'
# a manager session in the lane's folder must never be taken for the lane's session
mp="$work/mgrproj"; mkdir -p "$mp/.devin-crew/lanes"; echo 2000 > "$mp/.devin-crew/lanes/zz.started"
sqlite3 "$DEVIN_SESSIONS_DB" "create table if not exists sessions(id text, metadata text); alter table sessions add column working_directory text; alter table sessions add column created_at int;" 2>/dev/null
sqlite3 "$DEVIN_SESSIONS_DB" "insert into sessions(id,working_directory,created_at) values('manager-old','$(cd "$mp" && pwd -P)',1000);"
ok "no lane session when only an older (manager) session exists" '[ -z "$(bash $S/crew-observe.sh $mp zz --sid)" ]'
sqlite3 "$DEVIN_SESSIONS_DB" "insert into sessions(id,working_directory,created_at) values('lane-new','$(cd "$mp" && pwd -P)',2100);"
ok "the session created after the lane started is picked" '[ "$(bash $S/crew-observe.sh $mp zz --sid)" = "lane-new" ]'

echo "--- doctor under sandboxes"
d=$(CODEX_SANDBOX_NETWORK_DISABLED=1 bash "$S/crew-doctor.sh" "$proj" 2>&1); rc=$?
ok "doctor fails when Codex disabled the network, with the fix" '[ "$rc" = 1 ] && printf "%s" "$d" | grep -q "FAIL this shell has the network disabled.*network_access = true"'
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$work/rodata"; chmod 555 "$work/rodata"
  d=$(DEVIN_SESSIONS_DB="$work/rodata/sessions.db" bash "$S/crew-doctor.sh" "$proj" 2>&1); rc=$?
  ok "doctor fails when devin's data folder is read-only" '[ "$rc" = 1 ] && printf "%s" "$d" | grep -q "FAIL cannot write Devin.s data folder.*writable_roots"'
  chmod 755 "$work/rodata"
fi

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

echo "--- worktree merge, overlap, noise"
mp="$work/mproj"; mkdir -p "$mp"; git -C "$mp" init -q -b main
printf '# t\n\nbody\n' > "$mp/README.md"; echo x > "$mp/keep.txt"
git -C "$mp" add -A; git -C "$mp" -c user.name=t -c user.email=t@t commit -q -m i
mc="$mp/.devin-crew"; mkdir -p "$mc"
printf 'a\tREADME.md\na\ta.txt\nb\tREADME.md\nb\tb.txt\n' > "$mc/scopes.txt"
ok "scope lint flags two lanes owning README.md" 's=$(bash $S/crew-guard.sh $mp scopes); [ $? -eq 1 ] && printf "%s" "$s" | grep -q "SCOPE OVERLAP: a (README.md) and b (README.md)"'
printf 'a\tsrc/*\nb\tdocs/*\n' > "$work/scopes.ok"; mkdir -p "$work/okproj/.devin-crew"; cp "$work/scopes.ok" "$work/okproj/.devin-crew/scopes.txt"
ok "scope lint passes disjoint scopes" 'bash $S/crew-guard.sh $work/okproj scopes | grep -q "no overlaps"'
bash "$S/crew-worktree.sh" "$mp" add a 2>&1 | grep -q "WARNING: SCOPE OVERLAP" && echo "ok   worktree add warns about overlapping scopes" && pass=$((pass + 1)) || { echo "FAIL worktree add warns about overlapping scopes"; fail=$((fail + 1)); }
bash "$S/crew-worktree.sh" "$mp" add b >/dev/null 2>&1
wa="$mc/wt/a"; wb="$mc/wt/b"
printf '# t\n\nfrom a\n\nbody\n' > "$wa/README.md"; echo a > "$wa/a.txt"; mkdir -p "$wa/__pycache__"; echo junk > "$wa/__pycache__/x.cpython-314.pyc"
printf '# t\n\nfrom b\n\nbody\n' > "$wb/README.md"; echo b > "$wb/b.txt"
g=$(bash "$S/crew-guard.sh" "$mp" check 2>&1)
ok "check ignores bytecode" '! printf "%s" "$g" | grep -qi pyc'
ok "check reports the overlap" 'printf "%s" "$g" | grep -q "OVERLAP (lane a): README.md is owned by: a b"'
m=$(bash "$S/crew-worktree.sh" "$mp" merge a 2>&1)
ok "merge ignores bytecode and applies lane a" '! printf "%s" "$m" | grep -qi "NOT merged" && printf "%s" "$m" | grep -q "merged (2 files)" && grep -q "from a" $mp/README.md'
m=$(bash "$S/crew-worktree.sh" "$mp" merge b 2>&1); rc=$?
ok "conflicting file reported, rest still applied (partial merge)" '[ $rc -eq 1 ] && printf "%s" "$m" | grep -q "PARTIAL merge: 1 file(s) applied" && printf "%s" "$m" | grep -q "README.md" && [ -f $mp/b.txt ] && ! grep -q "from b" $mp/README.md'
bash "$S/crew-worktree.sh" "$mp" remove a >/dev/null 2>&1; bash "$S/crew-worktree.sh" "$mp" remove b >/dev/null 2>&1

printf '## Milestone 1: demo   verdict: PASS WITH NOTES\n' > "$rc_/QA.md"
r=$(bash "$S/crew-resume.sh" "$rp")
ok "all done + recorded verdict -> finish, not QA again" 'printf "%s" "$r" | grep -q "latest QA verdict is PASS WITH NOTES" && ! printf "%s" "$r" | grep -q "run milestone QA"'
printf '## Milestone 1: demo   verdict: FAIL\n' > "$rc_/QA.md"
ok "FAIL verdict -> failures become tasks" 'bash $S/crew-resume.sh $rp | grep -q "latest QA verdict is FAIL"'

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
CREW_RETRY_OK=1 STUB_EXIT=3 bash "$S/devin-lane.sh" "$proj" bad2 - "$work/task.md" >/dev/null 2>&1
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
printf 'DONE tests (v2): files changed: b | verified: y -> ok | open issues: none\n' >> "$crew/BOARD.md"
v3=$(bash "$S/crew-verify.sh" "$proj" tests 2>&1)
ok "off-format DONE line is a warning, not a false STALE" 'printf "%s" "$v3" | grep -q "^NO-CONTRACT-VERSION tests" && ! printf "%s" "$v3" | grep -q "^STALE"'
bash "$S/crew-verify.sh" "$proj" ack-contract api >/dev/null
v2=$(bash "$S/crew-verify.sh" "$proj" api 2>&1)
ok "ack clears a stale-contract flag for an unaffected lane" 'printf "%s" "$v2" | grep -q "^CONTRACT-ACKED api" && ! printf "%s" "$v2" | grep -q STALE'
printf '| t9 | api | s | - | sleep 30 | done |\n' > "$crew/TASKS.md"
v=$(CREW_VERIFY_SECS=2 bash "$S/crew-verify.sh" "$proj" api 2>&1)
ok "acceptance timeout enforced" 'printf "%s" "$v" | grep -q "^TIMEOUT t9 api"'

echo "--- conductor / collect / review"
mkcrew() { # mkcrew <name> -> prints project dir with TASKS for lanes a (acceptance: flag file) and b (true)
  local d="$work/$1"; mkdir -p "$d/.devin-crew/prompts"; printf 'version: 1\n' > "$d/.devin-crew/CONTRACTS.md"; : > "$d/.devin-crew/BOARD.md"
  printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n| t1 | a | x | - | test -f %s/flag.txt | open |\n| t2 | b | y | - | true | open |\n' "$d" > "$d/.devin-crew/TASKS.md"
  printf 'task one\n' > "$d/.devin-crew/prompts/t1.md"; printf 'task two\n' > "$d/.devin-crew/prompts/t2.md"; echo "$d"; }
DONES=$'DONE a: files changed: x | verified: test -> ok | contracts: v1 | open issues for other lanes: none\nDONE b: files changed: y | verified: true -> ok | contracts: v1 | open issues for other lanes: none'
export CREW_CONDUCT_POLL=0.3 CREW_CONDUCT_MAX_SECS=90
export CREW_AUTOQA=0   # the QA-lane tests below turn it on; the older conductor tests stop at MILESTONE-READY without a QA Devin

cp1=$(mkcrew cond-clean); touch "$cp1/flag.txt"
o=$(STUB_BOARD="$cp1/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" bash "$S/crew-conduct.sh" "$cp1" 2>&1)
ok "conductor: two ready tasks run in parallel lanes, ends MILESTONE-READY" 'printf "%s" "$o" | grep -q "^CONDUCT MILESTONE-READY" && [ "$(cat $cp1/.devin-crew/lanes/a.status)" = done ] && [ "$(cat $cp1/.devin-crew/lanes/b.status)" = done ]'
ok "conductor: tasks verified done" '! grep -qE "\| (open|running|review|failed) *\|? *$" $cp1/.devin-crew/TASKS.md'
ok "conductor: reviewer lane launched read-only for each lane" '[ -f $cp1/.devin-crew/lanes/a-rev.readonly ] && [ -f $cp1/.devin-crew/lanes/b-rev.status ] && grep -q "ROLE: reviewer" $STUB_OUT/prompts.log'
ok "conductor: missing findings file is a recorded skip, not a hang" 'printf "%s" "$o" | grep -q "REVIEW-SKIPPED a (no findings file)"'
ok "conductor: digest is short" '[ "$(printf "%s\n" "$o" | wc -l | tr -d " ")" -le 12 ]'

cp2=$(mkcrew cond-fix); grep -v "^| t2 " "$cp2/.devin-crew/TASKS.md" > "$cp2/TASKS.tmp" && mv "$cp2/TASKS.tmp" "$cp2/.devin-crew/TASKS.md"; c0=$(cat "$STUB_OUT/count")
o=$(STUB_BOARD="$cp2/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" STUB_WRITE="$cp2/flag.txt::ok" STUB_WRITE_FROM=$((c0 + 2)) CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cp2" 2>&1)
ok "conductor: failed acceptance resumes the lane with the failure, then passes" 'printf "%s" "$o" | grep -q "^CONDUCT MILESTONE-READY" && grep -q "needs fixes (acceptance/contract)" $STUB_OUT/prompts.log && grep -q "FAIL t1 a" $STUB_OUT/prompts.log'
ok "conductor: one fix round recorded" '[ "$(cat $cp2/.devin-crew/conduct/a.fix)" = 1 ]'

cp3=$(mkcrew cond-exhaust)
o=$(STUB_BOARD="$cp3/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" CREW_AUTOFIX=0 CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cp3" 2>&1)
ok "conductor: exhausted fix rounds end the run as BRAIN with the reason" 'printf "%s" "$o" | grep -q "^CONDUCT BRAIN a: fix rounds exhausted"'
bash "$S/crew-conduct.sh" "$cp3" --reset a >/dev/null
ok "conductor --reset clears the brain state" '[ "$(cat $cp3/.devin-crew/conduct/a.state)" = launched ] && [ ! -f $cp3/.devin-crew/conduct/a.brain ]'

cp4=$(mkcrew cond-user)
o=$(STUB_BOARD="$cp4/.devin-crew/BOARD.md" STUB_EXIT=1 STUB_OUTPUT="Error: 429 usage limit reached" CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cp4" 2>&1)
ok "conductor: a Devin error goes to the user, never retried" 'printf "%s" "$o" | grep -q "^CONDUCT NEEDS-USER .* RATE_OR_QUOTA"'

cp5=$(mkcrew cond-stuck); rm -f "$cp5/.devin-crew/prompts/t2.md"; touch "$cp5/flag.txt"
o=$(STUB_BOARD="$cp5/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cp5" 2>&1)
ok "conductor: a task without a brief is reported, not silently skipped" 'printf "%s" "$o" | grep -q "^CONDUCT STUCK t2.*no brief for: t2"'

cp7=$(mkcrew cond-mail); bash "$S/lane-msg.sh" "$cp7" send a orchestrator "DONE a: routine report" >/dev/null; bash "$S/lane-msg.sh" "$cp7" send b orchestrator "which port should I use?" >/dev/null
o=$(STUB_BOARD="$cp7/.devin-crew/BOARD.md" CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cp7" 2>&1)
ok "conductor: real orchestrator mail ends the run and prints the question" 'printf "%s" "$o" | grep -q "which port should I use" && printf "%s" "$o" | grep -q "^CONDUCT ORCHESTRATOR-MAIL"'
cp8=$(mkcrew cond-donemail); touch "$cp8/flag.txt"; bash "$S/lane-msg.sh" "$cp8" send a orchestrator "DONE a: routine report" >/dev/null
o=$(STUB_BOARD="$cp8/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cp8" 2>&1)
ok "conductor: a note or DONE report does not wake the brain (and is kept in the notes)" 'printf "%s" "$o" | grep -q "^CONDUCT MILESTONE-READY"'

cp9=$(mkcrew cond-wt); touch "$cp9/flag.txt"; ( cd "$cp9" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m base ) >/dev/null 2>&1
bash "$S/crew-worktree.sh" "$cp9" add a >/dev/null 2>&1
o=$(STUB_BOARD="$cp9/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" CREW_AUTOREVIEW=0 CREW_MERGE=0 bash "$S/crew-conduct.sh" "$cp9" 2>&1)
ok "conductor: a later lane gets a worktree cut from the merged tree" '[ -f $cp9/.devin-crew/lanes/b.workdir ] && grep -q "b: worktree created" $cp9/.devin-crew/events.log'

cpq=$(mkcrew cond-qa); touch "$cpq/flag.txt"
o=$(STUB_BOARD="$cpq/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" STUB_WRITE="$cpq/.devin-crew/qa/1.md::PASS WITH NOTES : all acceptance green" CREW_AUTOQA=1 CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$cpq" 2>&1)
ok "qa lane: a QA Devin runs after the last task and its verdict rides the MILESTONE-READY digest" 'printf "%s" "$o" | grep -q "^CONDUCT MILESTONE-READY" && printf "%s" "$o" | grep -q "^PASS WITH NOTES" && [ "$(cat $cpq/.devin-crew/lanes/qa-1.status)" = done ]'
ok "qa lane: read-only, role qa, brief carries the acceptance commands and the checklist" '[ -f $cpq/.devin-crew/lanes/qa-1.readonly ] && grep -q "ROLE: qa" $STUB_OUT/prompts.log && grep -q "acceptance: test -f" $cpq/.devin-crew/prompts/qa-1.md && grep -q "qa-checklist.md" $cpq/.devin-crew/prompts/qa-1.md'
cpf=$(mkcrew cond-qafail); touch "$cpf/flag.txt"
o=$(STUB_BOARD="$cpf/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" STUB_WRITE="$cpf/.devin-crew/qa/1.md::FAIL : no test for the error path" CREW_AUTOQA=1 CREW_AUTOREVIEW=0 CREW_FRESH_AFTER=1 bash "$S/crew-conduct.sh" "$cpf" 2>&1)
ok "qa lane: a failing verdict ends the run as QA-FAIL with the reason" 'printf "%s" "$o" | grep -q "^CONDUCT QA-FAIL FAIL : no test for the error path"'
ok "fresh-session: the Nth brain wake says to renew the session" 'printf "%s" "$o" | grep -q "^FRESH-SESSION: 1 brain wakes"'
bash "$S/crew-audit.sh" "$cpf" verdict >/dev/null 2>&1; rc=$?
ok "audit verdict: FAIL -> exit 1" '[ "$rc" = 1 ]'
bash "$S/crew-audit.sh" "$cp3" verdict >/dev/null 2>&1; rc=$?
ok "audit verdict: none yet -> exit 3" '[ "$rc" = 3 ]'
o=$(STUB_BOARD="$cpq/.devin-crew/BOARD.md" STUB_WRITE="$cpq/.devin-crew/REPORT.md::report: all milestones PASS" bash "$S/crew-conduct.sh" "$cpq" --report 2>&1)
ok "report lane: reporter Devin writes REPORT.md and the conductor prints it" 'printf "%s" "$o" | grep -q "^CONDUCT REPORT-READY" && printf "%s" "$o" | grep -q "all milestones PASS" && grep -q "ROLE: reporter" $STUB_OUT/prompts.log'

echo "--- init / stale install"
ip="$work/initproj"; mkdir -p "$ip/src" "$ip/.devin-crew"; git -C "$ip" init -q; echo x > "$ip/src/a.txt"; git -C "$ip" add -A >/dev/null 2>&1; git -C "$ip" -c user.email=t@t -c user.name=t commit -qm i >/dev/null 2>&1
printf 'a\tsrc/a*\nb\tsrc/b*\n' > "$ip/.devin-crew/scopes.txt"
o=$(bash "$S/crew-init.sh" "$ip" "true" 2>&1); rc=$?
ok "init: lock, baseline and a worktree per lane in one call" '[ "$rc" = 0 ] && printf "%s" "$o" | grep -q "^INIT OK: lanes: a b" && [ -d $ip/.devin-crew/wt/a ] && [ -d $ip/.devin-crew/wt/b ] && [ -f $ip/.devin-crew/LOCK ]'
ok "init: output stays short" '[ "$(printf "%s\n" "$o" | wc -l | tr -d " ")" -le 8 ]'
o=$(bash "$S/crew-init.sh" "$work/proj" "true" 2>&1); rc=$?
ok "init: refuses without scopes.txt" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "INIT STOP"'
stale="$work/stale-skill"; mkdir -p "$stale/scripts"; cp "$S/crew-doctor.sh" "$stale/scripts/"
o=$(bash "$stale/scripts/crew-doctor.sh" "$ip" 2>&1)
ok "doctor: a stale skill install is flagged" 'printf "%s" "$o" | grep -q "WARN this skill install .* is stale: missing"'

echo "--- ship"
sp="$work/shipproj"; sr="$work/shipremote.git"; git init -q --bare "$sr"; mkdir -p "$sp/src" "$sp/.devin-crew/qa"; git -C "$sp" init -q -b main
echo old > "$sp/src/a.txt"; echo mine > "$sp/user-wip.txt"; git -C "$sp" add -A >/dev/null; git -C "$sp" -c user.email=t@t -c user.name=t commit -qm init; git -C "$sp" remote add origin "$sr"; git -C "$sp" push -q origin main 2>/dev/null
echo new > "$sp/src/a.txt"; echo extra > "$sp/src/b.txt"; echo wip2 > "$sp/user-wip.txt"
printf 'a\tsrc/*\n' > "$sp/.devin-crew/scopes.txt"; printf 'user-wip.txt\n' > "$sp/.devin-crew/prework.files"
printf '# Objective: add the b module\n' > "$sp/.devin-crew/PLAN.md"; printf 'report body\n' > "$sp/.devin-crew/REPORT.md"
o=$(bash "$S/crew-ship.sh" "$sp" --print 2>&1)
ok "ship --print: dry run changes nothing and names the branch" 'printf "%s" "$o" | grep -q "SHIP DRY RUN: branch crew/add-the-b-module" && [ "$(git -C $sp symbolic-ref --short HEAD)" = main ]'
o=$(bash "$S/crew-ship.sh" "$sp" 2>&1); rc=$?
ok "ship: refuses without the user's authorization" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "not authorized"'
o=$(CREW_SHIP_OK=1 bash "$S/crew-ship.sh" "$sp" 2>&1); rc=$?
ok "ship: refuses without a QA verdict" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "QA verdict"'
printf 'FAIL : x\n' > "$sp/.devin-crew/qa/1.md"
o=$(CREW_SHIP_OK=1 bash "$S/crew-ship.sh" "$sp" 2>&1); rc=$?
ok "ship: refuses a FAIL verdict" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "QA verdict is .FAIL"'
printf 'PASS : ok\n' > "$sp/.devin-crew/qa/1.md"; printf 'AWS=AKIAABCDEFGHIJKLMNOP\n' > "$sp/src/c.txt"
o=$(CREW_SHIP_OK=1 bash "$S/crew-ship.sh" "$sp" 2>&1); rc=$?
ok "ship: secrets scan blocks and shows file:line, not the value" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "possible secret: src/c.txt:1" && ! printf "%s" "$o" | grep -q AKIAABC'
rm "$sp/src/c.txt"
o=$(CREW_SHIP_OK=1 bash "$S/crew-ship.sh" "$sp" 2>&1); rc=$?
ok "ship: branch, commit, push and PR in one call" '[ "$rc" = 0 ] && printf "%s" "$o" | grep -q "^SHIP OK https://github.com/stub/repo/pull/7" && [ "$(git -C $sp symbolic-ref --short HEAD)" = crew/add-the-b-module ] && git -C $sr show-ref --verify -q refs/heads/crew/add-the-b-module'
ok "ship: PR body is REPORT.md, base is main" 'grep -q "pr create --base main --head crew/add-the-b-module .*--body-file .*REPORT.md" $STUB_OUT/gh.log'
ok "ship: the user's own prior WIP and .devin-crew stay out of the commit" '! git -C $sp show --name-only --format= HEAD | grep -qE "user-wip|devin-crew" && git -C $sp show --name-only --format= HEAD | grep -q "src/b.txt"'
ok "ship: never pushed main" '[ "$(git -C $sr rev-parse main)" = "$(git -C $sp rev-parse main)" ]'

echo "--- autopilot"
FIXDONES="$DONES"$'\nDONE fix1r1-1: files changed: flag.txt | verified: test -f flag.txt -> ok | contracts: v1 | open issues for other lanes: none'
export CREW_AUTOQA=1 CREW_AUTOREVIEW=0
ap1=$(mkcrew ap-ms); mkdir -p "$ap1/.devin-crew/milestones"; touch "$ap1/flag.txt"
printf '# first slice\n| t1 | a | x | - | test -f %s/flag.txt | open |\n' "$ap1" > "$ap1/.devin-crew/milestones/m1.tasks"
printf '# second slice\n| t2 | b | y | - | true | open |\n' > "$ap1/.devin-crew/milestones/m2.tasks"
printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n' > "$ap1/.devin-crew/TASKS.md"
W="$ap1/.devin-crew/qa/1.md::PASS : m1@@@$ap1/.devin-crew/qa/2.md::PASS : m2@@@$ap1/.devin-crew/qa/3.md::PASS : final@@@$ap1/.devin-crew/REPORT.md::report ok"
o=$(STUB_BOARD="$ap1/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" STUB_WRITE="$W" bash "$S/crew-autopilot.sh" "$ap1" run 2>&1)
ok "autopilot: two milestones, QA each, a final whole-objective QA, report, then DONE" 'printf "%s" "$o" | grep -q "^DONE:" && [ "$(cat $ap1/.devin-crew/autopilot/loaded | tr "\n" " ")" = "1 2 " ] && [ -f $ap1/.devin-crew/qa/3.md ] && [ -f $ap1/.devin-crew/autopilot/DONE ] && grep -q "FINAL: whole objective" $ap1/.devin-crew/MILESTONE'
ok "autopilot: without authorization it stops at the report and says so" 'grep -q "not authorized to push" $ap1/.devin-crew/autopilot/DONE'
ok "autopilot --status reads DONE" 'bash $S/crew-autopilot.sh $ap1 --status | grep -q "^autopilot: DONE"'

ap2=$(mkcrew ap-fix); touch "$ap2/flag.txt"
FX=$'FAIL : error path untested\nsrc/x:1: high: no test for the error path. add one.\nFIXTASK: new | flag.txt | test -f flag.txt | add the error-path test'
W="3=$ap2/.devin-crew/qa/1.md::$FX@@@5=$ap2/.devin-crew/qa/2.md::PASS : fixed@@@6>$ap2/.devin-crew/REPORT.md::report ok"
mkdir -p "$work/o-ap2"; o=$(STUB_OUT="$work/o-ap2" STUB_BOARD="$ap2/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$FIXDONES" STUB_WRITE="$W" bash "$S/crew-autopilot.sh" "$ap2" run 2>&1)
ok "autopilot: QA-FAIL becomes fix tasks, they run, QA passes, run finishes" 'printf "%s" "$o" | grep -q "^DONE:" && grep -q "fix1r1-1" $ap2/.devin-crew/TASKS.md && [ -s $ap2/.devin-crew/prompts/fix1r1-1.md ] && grep -q "add the error-path test" $ap2/.devin-crew/prompts/fix1r1-1.md && [ "$(cat $ap2/.devin-crew/acceptance/fix1r1-1.sh)" = "test -f flag.txt" ]'

ap3=$(mkcrew ap-same); touch "$ap3/flag.txt"
W="3=$ap3/.devin-crew/qa/1.md::$FX@@@5=$ap3/.devin-crew/qa/2.md::$FX"
mkdir -p "$work/o-ap3"; o=$(STUB_OUT="$work/o-ap3" STUB_BOARD="$ap3/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$FIXDONES" STUB_WRITE="$W" bash "$S/crew-autopilot.sh" "$ap3" run 2>&1)
ok "autopilot: the same QA failure twice stops for a decision, with a notification file" 'printf "%s" "$o" | grep -q "^ATTENTION: QA found the same failures again" && [ -f $ap3/.devin-crew/autopilot/ATTENTION ]'

ap4=$(mkcrew ap-user)
o=$(STUB_BOARD="$ap4/.devin-crew/BOARD.md" STUB_EXIT=1 STUB_OUTPUT="Error: 429 usage limit reached" bash "$S/crew-autopilot.sh" "$ap4" run 2>&1)
ok "autopilot: a Devin error stops the run as ATTENTION (never retried)" 'printf "%s" "$o" | grep -q "^ATTENTION: NEEDS-USER" && bash $S/crew-autopilot.sh $ap4 --status | grep -q "^autopilot: ATTENTION"'
export CREW_AUTOQA=0

echo "--- roles / plan"
ok "roles: the team is listed (architect, backend, frontend, security, a11y ...)" 'bash $S/crew-roles.sh list | grep -q "^architect" && bash $S/crew-roles.sh list | grep -q "^security" && bash $S/crew-roles.sh list | grep -q "^database"'
ok "roles: scope globs pick the fitting role" '[ "$(bash $S/crew-roles.sh pick-scope "web/App.tsx web/x.css")" = frontend ] && [ "$(bash $S/crew-roles.sh pick-scope "migrations/001.sql")" = database ] && [ "$(bash $S/crew-roles.sh pick-scope "src/api/* tests/*")" = backend ] && [ "$(bash $S/crew-roles.sh pick-scope "weird/x.zzz")" = implementer ] && [ "$(bash $S/crew-roles.sh pick-scope "tests/*")" = tests ]'
rp="$work/roleproj"; mkdir -p "$rp/.devin-crew/prompts" "$rp/web"; git -C "$rp" init -q -b main; echo a > "$rp/a.txt"; git -C "$rp" add -A >/dev/null; git -C "$rp" -c user.email=t@t -c user.name=t commit -qm i
printf 'version: 1\n' > "$rp/.devin-crew/CONTRACTS.md"; : > "$rp/.devin-crew/BOARD.md"; printf 'ui\tweb/App.tsx\n' > "$rp/.devin-crew/scopes.txt"
printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n| u1 | ui | web/* | - | test -f %s/web/App.tsx | open |\n' "$rp" > "$rp/.devin-crew/TASKS.md"; echo "build the page" > "$rp/.devin-crew/prompts/u1.md"
ok "roles: specialists follow the change (code -> security, UI -> a11y)" 'echo "x" > $rp/web/App.tsx; [ "$(bash $S/crew-roles.sh specialists $rp)" = "security a11y" ] && [ "$(CREW_SPECIALISTS=none bash $S/crew-roles.sh specialists $rp)" = "" ]'
mkdir -p "$work/o-role"
o=$(STUB_OUT="$work/o-role" STUB_BOARD="$rp/.devin-crew/BOARD.md" STUB_APPEND_BOARD="DONE ui: files changed: web/App.tsx | verified: ok | contracts: v1 | open issues for other lanes: none" STUB_WRITE="$rp/.devin-crew/qa/1.md::PASS : fine@@@$rp/.devin-crew/qa/spec/1-security.md::NO FINDINGS@@@$rp/.devin-crew/qa/spec/1-a11y.md::NO FINDINGS" CREW_AUTOQA=1 CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$rp" 2>&1)
ok "conductor: task roles come from the files (ROLE: frontend)" 'grep -q "ROLE: frontend" $work/o-role/prompts.log'
ok "conductor: specialists (security, a11y) run before the QA Devin, then MILESTONE-READY" 'printf "%s" "$o" | grep -q "^CONDUCT MILESTONE-READY" && grep -q "ROLE: security" $work/o-role/prompts.log && grep -q "ROLE: a11y (specialist" $work/o-role/prompts.log && [ -f $rp/.devin-crew/lanes/spec-security-1.status ] && grep -q "Specialist reviewers already looked" $rp/.devin-crew/prompts/qa-1.md'
export CREW_AUTOQA=0

echo "--- race / brain stats / per-role model"
rc_=$work/raceproj; mkdir -p "$rc_/src" "$rc_/.devin-crew/prompts"; git -C "$rc_" init -q -b main; echo a > "$rc_/src/a.txt"; git -C "$rc_" add -A >/dev/null; git -C "$rc_" -c user.email=t@t -c user.name=t commit -qm i
printf 'version: 1\n' > "$rc_/.devin-crew/CONTRACTS.md"; : > "$rc_/.devin-crew/BOARD.md"; printf 'a\tsrc/a.txt\n' > "$rc_/.devin-crew/scopes.txt"
printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n| r1 | a | src/a.txt | - | true | open |\n' > "$rc_/.devin-crew/TASKS.md"; echo "risky task" > "$rc_/.devin-crew/prompts/r1.md"
o=$(bash "$S/crew-race.sh" "$rc_" r1 2>&1)
ok "race: twin row, scopes, brief and worktrees are created" 'printf "%s" "$o" | grep -q "^RACE r1: a vs a-alt" && grep -q "r1-alt | a-alt" $rc_/.devin-crew/TASKS.md && grep -q "^a-alt" $rc_/.devin-crew/scopes.txt && [ -d $rc_/.devin-crew/wt/a-alt ] && grep -q "another Devin solves this same task" $rc_/.devin-crew/prompts/r1-alt.md'
RD=$'DONE a: files changed: src/a.txt | verified: true -> ok | contracts: v1 | open issues for other lanes: none\nDONE a-alt: files changed: src/a.txt | verified: true -> ok | contracts: v1 | open issues for other lanes: none'
mkdir -p "$work/o-race"; o=$(STUB_OUT="$work/o-race" STUB_BOARD="$rc_/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$RD" CREW_AUTOQA=0 CREW_AUTOREVIEW=0 bash "$S/crew-conduct.sh" "$rc_" 2>&1)
ok "race: the conductor keeps one twin, discards the other, and finishes the milestone" 'printf "%s" "$o" | grep -q "^CONDUCT MILESTONE-READY" && printf "%s" "$o" | grep -q "^RACE-WON" && [ "$( (cat $rc_/.devin-crew/conduct/a.state; cat $rc_/.devin-crew/conduct/a-alt.state) | sort | tr "\n" " ")" = "discarded merged " ]'

bash "$S/crew-brain-stats.sh" "$work/proj" >/dev/null 2>&1; ok "brain stats runs on a project with no transcripts" '[ "$(CREW_CLAUDE_PROJECTS=$work/none CREW_CODEX_SESSIONS=$work/none bash $S/crew-brain-stats.sh $work/proj | tail -1)" = "verdict: no brain transcripts found for this project" ]'
bt="$work/brainproj"; mkdir -p "$bt"; bd="$work/claudeprojects/$(printf '%s' "$(cd "$bt" && pwd -P)" | sed -E 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$bd"
python3 -I - "$bd/s1.jsonl" <<'PY'
import json,sys
rows=[]
for i,cmd in enumerate(["cargo test --workspace","bash /x/crew-conduct.sh /p","sed -i '' s/a/b/ src/x.rs"]):
    rows.append({"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0,"output_tokens":50},"content":[{"type":"tool_use","id":str(i),"name":"Bash","input":{"command":cmd}}]}})
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows))
PY
o=$(CREW_CLAUDE_PROJECTS="$work/claudeprojects" CREW_CODEX_SESSIONS="$work/none" CREW_LEDGER="$work/none.tsv" bash "$S/crew-brain-stats.sh" "$bt" 2>&1)
ok "brain stats: counts turns and flags brain test runs and edits as contract violations" 'printf "%s" "$o" | grep -q "3 turns" && printf "%s" "$o" | grep -q "VIOLATION run tests/build 1" && printf "%s" "$o" | grep -q "VIOLATION edit files 1" && printf "%s" "$o" | grep -q "^verdict: 2 brain call"'

CREW_ROLE=qa CREW_MODEL_QA=big-model bash "$S/devin-lane.sh" "$proj" qamodel - "$work/task.md" >/dev/null 2>&1
ok "per-role model: CREW_MODEL_QA applies to the qa role only" '[ "$(cat $crew/lanes/qamodel.model)" = "big-model" ] && [ "$(cat $crew/lanes/mdl.model)" = "my-other-model" ]'

echo "--- where (the one command's router)"
wp="$work/whereproj"; mkdir -p "$wp"
w() { bash "$S/crew-where.sh" "$wp" 2>&1; }
ok "where: an empty project is NO-CREW and the next step is asking for the goal" '[ "$(w | head -1)" = "STATE NO-CREW" ] && w | grep -q "^NEXT: ask the user for the goal"'
mkdir -p "$wp/.devin-crew/lanes" "$wp/.devin-crew/draft"; echo running > "$wp/.devin-crew/lanes/plan.status"
ok "where: architect running -> DRAFTING" '[ "$(w | head -1)" = "STATE DRAFTING" ]'
echo done > "$wp/.devin-crew/lanes/plan.status"; printf '# Objective: speed up parse\n' > "$wp/.devin-crew/draft/PLAN.md"
ok "where: finished draft -> DRAFT-READY with the goal and the go question" '[ "$(w | head -1)" = "STATE DRAFT-READY" ] && w | grep -q "^GOAL: speed up parse" && w | grep -q "go with a pull request"'
printf '# Objective: speed up parse\napproved: 2026-11-18\n' > "$wp/.devin-crew/PLAN.md"
ok "where: approved plan, nothing running -> STOPPED (continue)" '[ "$(w | head -1)" = "STATE STOPPED" ]'
mkdir -p "$wp/.devin-crew/autopilot"; sleep 30 & slp=$!; echo $slp > "$wp/.devin-crew/autopilot/pid"
ok "where: live autopilot -> RUNNING" '[ "$(w | head -1)" = "STATE RUNNING" ]'
kill $slp 2>/dev/null; echo "Devin usage limit" > "$wp/.devin-crew/lanes/api.needs-user"
ok "where: a lane waiting on the user -> NEEDS-USER" '[ "$(w | head -1)" = "STATE NEEDS-USER" ] && w | grep -q "lane api"'
rm "$wp/.devin-crew/lanes/api.needs-user"; echo "stop reason" > "$wp/.devin-crew/autopilot/ATTENTION"
ok "where: autopilot stopped with a reason -> ATTENTION" '[ "$(w | head -1)" = "STATE ATTENTION" ]'
echo "DONE x" > "$wp/.devin-crew/autopilot/DONE"
ok "where: finished run -> DONE (relay the report and PR)" '[ "$(w | head -1)" = "STATE DONE" ] && w | grep -q "pull request link"'
ok "where: at most 5 lines, changes nothing" '[ "$(w | wc -l | tr -d " ")" -le 5 ]'

pp="$work/planproj"; mkdir -p "$pp"; git -C "$pp" init -q -b main; echo a > "$pp/a.py"; git -C "$pp" add -A >/dev/null; git -C "$pp" -c user.email=t@t -c user.name=t commit -qm i
bash "$S/crew-plan.sh" "$pp" draft "make it faster" --print >/dev/null 2>&1
ok "plan draft: the architect brief carries the goal, the role catalog and the file formats" 'grep -q "make it faster" $pp/.devin-crew/prompts/plan-1.md && grep -q "frontend" $pp/.devin-crew/prompts/plan-1.md && grep -q "milestones/m1.tasks" $pp/.devin-crew/prompts/plan-1.md && [ ! -f $pp/.devin-crew/lanes/plan.status ]'
touch "$pp/.devin-crew/trusted"
o=$(rm -f $pp/.devin-crew/trusted; STUB_OUT="$work/o-trust" STUB_OUTPUT="Error: Refusing to run in an untrusted workspace" bash "$S/crew-plan.sh" "$pp" draft "x" 2>&1); mkdir -p "$work/o-trust"
ok "plan draft: an untrusted workspace stops before any Devin is launched, with the fix" 'printf "%s" "$o" | grep -q "PLAN STOP: preflight failed" && [ ! -f $pp/.devin-crew/lanes/plan.status ]'
touch "$pp/.devin-crew/trusted"
D="$pp/.devin-crew/draft"; PR="$pp/.devin-crew/prompts"
WF="$D/PLAN.md::# Objective: speed up parse@@@$D/SPEC.md::1. parse is 2x faster@@@$D/CONTRACTS.md::version: 1@@@$D/ROSTER.md::- core (backend): owns a.py@@@$D/scopes.txt::$(printf 'core\ta.py')@@@$D/baseline.cmd::true@@@$D/QUESTIONS.md::NONE@@@$D/milestones/m1.tasks::$(printf '# speed\n| t1 | core | a.py | - | true | open |')@@@$D/prompts/t1.md::make parse faster"
mkdir -p "$work/o-plan"; STUB_OUT="$work/o-plan" STUB_WRITE="$WF" bash "$S/crew-plan.sh" "$pp" draft "make it faster" >/dev/null 2>&1
o=$(bash "$S/crew-plan.sh" "$pp" check 2>&1); rc=$?
ok "plan check: a complete draft validates and summarizes" '[ "$rc" = 0 ] && printf "%s" "$o" | grep -q "^DRAFT: 1 milestone(s), 1 task(s), 1 lane(s)" && printf "%s" "$o" | grep -q "QUESTIONS: none"'
rm "$D/prompts/t1.md"; o=$(bash "$S/crew-plan.sh" "$pp" check 2>&1); rc=$?
ok "plan check: a task without a brief is a problem" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "PROBLEM: t1: no brief"'
echo "make parse faster" > "$D/prompts/t1.md"
o=$(bash "$S/crew-plan.sh" "$pp" apply --ship 2>&1)
ok "plan apply: plan, scopes, briefs and milestones in place; ship authorized in PLAN.md" 'printf "%s" "$o" | grep -q "^PLAN APPLIED" && grep -q "^ship: yes" $pp/.devin-crew/PLAN.md && [ -s $pp/.devin-crew/prompts/t1.md ] && [ -f $pp/.devin-crew/milestones/m1.tasks ] && grep -q "^| id " $pp/.devin-crew/TASKS.md && grep -q "^core" $pp/.devin-crew/scopes.txt'

cp6=$(mkcrew collect); touch "$cp6/flag.txt"; STUB_BOARD="$cp6/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" bash "$S/devin-lane.sh" "$cp6" a - "$cp6/.devin-crew/prompts/t1.md" >/dev/null 2>&1
o=$(bash "$S/crew-collect.sh" "$cp6" a 2>&1); rc=$?
ok "collect: clean lane -> VERDICT CLEAN, exit 0" '[ "$rc" = 0 ] && printf "%s" "$o" | grep -q "^VERDICT CLEAN" && printf "%s" "$o" | grep -q "PASS t1 a"'
rm -f "$cp6/flag.txt"; bash "$S/crew-tasks.sh" "$cp6" set t1 review
o=$(bash "$S/crew-collect.sh" "$cp6" a 2>&1); rc=$?
ok "collect: failing acceptance -> VERDICT FIX, exit 1" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "^VERDICT FIX (acceptance failed)"'
o=$(bash "$S/crew-collect.sh" "$cp6" nolane 2>&1); rc=$?
ok "collect: unknown lane -> BRAIN" '[ "$rc" = 2 ] && printf "%s" "$o" | grep -q "^VERDICT BRAIN"'
bash "$S/crew-review.sh" "$cp6" a --print >/dev/null 2>&1
ok "review --print writes a brief with acceptance command and no launch" 'grep -q "acceptance: test -f" $cp6/.devin-crew/prompts/a-rev-1.md && [ ! -f $cp6/.devin-crew/lanes/a-rev.status ]'
printf 'src/x.py:3: high: unchecked input. validate.\nsrc/y.py:9: low: nit.\n' > "$cp6/.devin-crew/reviews/a.md"
o=$(bash "$S/crew-review.sh" "$cp6" a --findings 2>&1); rc=$?
ok "review --findings counts severities, exit 1 on high/med" '[ "$rc" = 1 ] && printf "%s" "$o" | grep -q "REVIEW a: high=1 med=0"'
unset CREW_CONDUCT_POLL CREW_CONDUCT_MAX_SECS

cp10=$(mkcrew verify-open); touch "$cp10/flag.txt"; STUB_BOARD="$cp10/.devin-crew/BOARD.md" STUB_APPEND_BOARD="$DONES" bash "$S/devin-lane.sh" "$cp10" a - "$cp10/.devin-crew/prompts/t1.md" >/dev/null 2>&1
printf '| id | lane | scope | depends | acceptance | status |\n|----|------|-------|---------|------------|--------|\n| t1 | a | x | - | true | review |\n| t9 | a | y | t1 | true | open |\n' > "$cp10/.devin-crew/TASKS.md"
v=$(bash "$S/crew-verify.sh" "$cp10" a 2>&1)
ok "verify: an open (never launched) task is not marked done by a passing acceptance command" 'printf "%s" "$v" | grep -q "^SKIP t9 a: task not started" && printf "%s" "$v" | grep -q "^PASS t1 a" && grep -q "| t9 | a | y | t1 | true | open" $cp10/.devin-crew/TASKS.md'

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
