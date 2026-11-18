#!/usr/bin/env bash
# What the brain (Claude Code / Codex session) cost against what the Devins cost, and whether the brain kept the Brain contract.
#   bash crew-brain-stats.sh <project>
# Reads the brain's transcripts for this project (Claude: ~/.claude/projects/<path-with-dashes>/*.jsonl; Codex: ~/.codex/sessions/**/rollout-*.jsonl that
# mention the project path) and the Devin usage ledger. Prints turns, tokens re-read, the largest context, brain tool calls by kind, Devin tokens,
# the brain/Devin ratio and one verdict line. Local only; transcripts are read, never copied. Tokens are what the transcripts report.
# env: CREW_CLAUDE_PROJECTS (default ~/.claude/projects), CREW_CODEX_SESSIONS (default ~/.codex/sessions), CREW_LEDGER.
set -u
proj=$(cd "${1:-.}" && pwd -P) || exit 2
here="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I - "$proj" "${CREW_CLAUDE_PROJECTS:-$HOME/.claude/projects}" "${CREW_CODEX_SESSIONS:-$HOME/.codex/sessions}" "${CREW_LEDGER:-$here/usage/ledger.tsv}" <<'PY'
import sys, os, re, json, glob, collections
proj, cdir, xdir, ledger = sys.argv[1:5]
enc = re.sub(r'[^A-Za-z0-9]', '-', proj)
files = glob.glob(os.path.join(cdir, enc, "*.jsonl"))
turns = cr = out = peak = 0
kinds = collections.Counter()
TEST = re.compile(r'\b(cargo (test|clippy|build|audit|deny|fmt|check)|npm (test|run|install)|pnpm |yarn (test|build)|pytest|python3? -m (unittest|pytest)|go (test|build|vet)|swift (test|build)|xcodebuild|make (test|build|check)|tsc\b|eslint|ruff|mypy|gradlew|mvn )')
EDIT = re.compile(r'(sed -i|perl -pi|\btee\b|(^|[;&|] *)cat *> *(?!\S*\.devin-crew|/tmp|"?\$TMPDIR))')
ORCH = re.compile(r'crew-(conduct|autopilot|plan|init|ship|audit|status|resume|doctor|collect|brain)|devin-lane|lane-msg|crew-(worktree|guard|router|budget|observe|verify|qa)')
def feed_claude(f):
    global turns, cr, out, peak
    for l in open(f, errors="replace"):
        try: o = json.loads(l)
        except Exception: continue
        m = o.get("message") or {}; u = m.get("usage")
        if o.get("type") == "assistant" and u:
            turns += 1; c = u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("input_tokens", 0)
            cr += c; out += u.get("output_tokens", 0); peak = max(peak, c)
        for b in (m.get("content") if isinstance(m.get("content"), list) else []):
            if b.get("type") == "tool_use":
                if b["name"] != "Bash": kinds["other:" + b["name"].split("__")[-1]] += 1; continue
                s = (b.get("input") or {}).get("command", "")
                if ORCH.search(s): kinds["orchestration"] += 1
                elif TEST.search(s): kinds["VIOLATION run tests/build"] += 1
                elif EDIT.search(s): kinds["VIOLATION edit files"] += 1
                else: kinds["read/grep/misc"] += 1
for f in files: feed_claude(f)
xs = 0
for f in glob.glob(os.path.join(xdir, "**", "rollout-*.jsonl"), recursive=True):
    try:
        if proj not in open(f, errors="replace").read(200000): continue
    except Exception: continue
    xs += 1; last = None
    for l in open(f, errors="replace"):
        try: o = json.loads(l)
        except Exception: continue
        p = o.get("payload") or {}
        if o.get("type") == "event_msg" and p.get("type") == "token_count" and p.get("info"): last = p["info"]
        if o.get("type") == "response_item" and p.get("type") in ("function_call", "custom_tool_call"):
            s = str(p.get("arguments") or p.get("input") or "")
            if ORCH.search(s): kinds["orchestration"] += 1
            elif TEST.search(s): kinds["VIOLATION run tests/build"] += 1
            elif EDIT.search(s): kinds["VIOLATION edit files"] += 1
            else: kinds["read/grep/misc"] += 1
    if last:
        t = last.get("total_token_usage", {}); cr += t.get("input_tokens", 0); out += t.get("output_tokens", 0)
        peak = max(peak, (last.get("last_token_usage") or {}).get("input_tokens", 0)); turns += 1
dev = {}
if os.path.exists(ledger):
    for l in open(ledger, errors="replace"):
        f = l.rstrip("\n").split("\t")
        if f[0] == "turn" and len(f) >= 17 and f[2].startswith(proj):
            try: dev[(f[2], f[3])] = int(float(f[10]))
            except ValueError: pass
devtok = sum(dev.values())
M = lambda n: "%.1fM" % (n / 1e6)
print("brain: %d session file(s) (%d Claude, %d Codex), %d turns, %s tokens read, %s generated, largest context %dk" % (len(files) + xs, len(files), xs, turns, M(cr), M(out), peak // 1000))
print("brain tool calls: " + (", ".join("%s %d" % kv for kv in kinds.most_common(7)) or "none found"))
print("devins: %d lanes, %s tokens read%s" % (len(dev), M(devtok), "" if dev else " (no ledger rows for this project)"))
viol = sum(v for k, v in kinds.items() if k.startswith("VIOLATION"))
ratio = (cr / devtok) if devtok else 0
notes = []
if viol: notes.append("%d brain call(s) ran project tests/builds or edited files: that work belongs to a Devin lane" % viol)
if peak > 300000: notes.append("context reached %dk: renew the session at FRESH-SESSION (/devin-crew resume)" % (peak // 1000))
if devtok and ratio > 1: notes.append("brain read %.1fx what all Devins read: shift work to lanes, decide less often" % ratio)
print("verdict: " + ("OK, the brain stayed a conductor" if turns and not notes else ("no brain transcripts found for this project" if not turns else "; ".join(notes))))
PY
