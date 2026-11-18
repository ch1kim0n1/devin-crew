#!/usr/bin/env bash
# End-to-end test with the REAL Devin CLI: vague goal -> architect draft -> plan -> init -> autopilot (lanes, QA, report) on a throwaway git project.
# Opt-in: it uses your Devin account (the free default model) and takes roughly 10-40 minutes. Nothing leaves the temp folder (no push, no PR).
#   CREW_E2E=1 bash tests/e2e-real.sh            keeps the temp project and prints its path
set -u
[ "${CREW_E2E:-0}" = 1 ] || { echo "skip: set CREW_E2E=1 (real Devin, 10-40 min)"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; S="$here/../scripts"
command -v devin >/dev/null 2>&1 || { echo "FAIL devin not installed"; exit 1; }
devin auth status >/dev/null 2>&1 || { echo "FAIL devin is not logged in (devin auth login)"; exit 1; }
# Devin refuses untrusted folders and this skill never bypasses that, so the test project lives at a fixed path you trust ONCE:
#   mkdir -p ~/.cache/devin-crew-e2e/proj && cd ~/.cache/devin-crew-e2e/proj && devin     (accept the trust prompt, then exit)
base=${CREW_E2E_DIR:-$HOME/.cache/devin-crew-e2e}; p="$base/proj"
[ -d "$p" ] || { echo "SETUP NEEDED: mkdir -p $p && cd $p && devin   (accept the workspace trust prompt once, then rerun)"; exit 2; }
# reset the project: only ever delete inside it, and only if it is the test folder
case "$p" in */devin-crew-e2e/proj) find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} + ;; *) echo "refusing to clean $p"; exit 2;; esac
mkdir -p "$p/tests"; cd "$p" || exit 1; git init -q -b main
cat > textutil.py <<'PY'
def shout(text):
    return text.upper() + "!"
PY
printf 'import unittest\nfrom textutil import shout\n\nclass T(unittest.TestCase):\n    def test_shout(self):\n        self.assertEqual(shout("hi"), "HI!")\n\nif __name__ == "__main__":\n    unittest.main()\n' > tests/test_textutil.py
printf '# textutil\n\nTiny text helpers.\n' > README.md
git add -A && git -c user.email=e2e@local -c user.name=e2e commit -qm init
crew="$p/.devin-crew"; t0=$(date +%s); pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1   [$2]"; fi; }
echo "project: $p"
bash "$S/crew-plan.sh" "$p" draft "add a slugify function to textutil.py, with unit tests, and document it in the README" || exit 1
for _ in $(seq 1 180); do sleep 10; st=$(cat "$crew/lanes/plan.status" 2>/dev/null); case "$st" in done|failed*) break;; esac; done
ok "architect Devin finished" '[ "$(cat $crew/lanes/plan.status)" = done ]'
bash "$S/crew-plan.sh" "$p" check; rc=$?
ok "draft plan validates (briefs, scopes, roles, <=5 lanes)" '[ "$rc" = 0 ]'
[ "$rc" = 0 ] || { echo "stopping: the draft is not usable (see $crew/draft)"; exit 1; }
bash "$S/crew-plan.sh" "$p" apply --budget 300 || exit 1
bash "$S/crew-init.sh" "$p" "python3 -m unittest" --trust || exit 1
CREW_AUTOPILOT_MAX_SECS=${CREW_AUTOPILOT_MAX_SECS:-3000} bash "$S/crew-autopilot.sh" "$p" run
ok "autopilot reached DONE" '[ -f $crew/autopilot/DONE ]'
ok "QA verdict is PASS or PASS WITH NOTES" 'bash $S/crew-audit.sh $p verdict >/dev/null 2>&1'
ok "the project tests pass in the main tree" '(cd $p && python3 -m unittest >/dev/null 2>&1)'
ok "slugify exists and works" '(cd $p && python3 -c "from textutil import slugify; assert slugify(\"Hello, World!\") == \"hello-world\"")'
ok "report written" '[ -s $crew/REPORT.md ]'
ok "README documents it" 'grep -qi slugify $p/README.md'
ok "no push or PR was attempted" '[ ! -f $crew/PR_URL ]'
echo "elapsed: $(( ($(date +%s) - t0) / 60 )) min | project kept at $p"
echo "brain stats are not applicable (no brain session in this test); lane effort:"; bash "$S/crew-report.sh" "$p" | head -12
echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
