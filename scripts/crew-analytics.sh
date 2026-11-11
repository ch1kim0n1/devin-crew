#!/usr/bin/env bash
# How Claude has used Devin across all projects, from the usage ledger (written by devin-lane.sh and crew-qa-history.sh).
#   bash crew-analytics.sh            text summary: usage, time, tasks, projects, tokens, failures, QA, fun facts
#   bash crew-analytics.sh hint       3-4 lines on earlier crews (cost, first-try rate, stops, QA) for the proposal; silent when no history
#   bash crew-analytics.sh viz [out]  also write a self-contained HTML report with charts (default usage/report.html); prints the path
# Ledger: $CREW_LEDGER or <skill>/usage/ledger.tsv. Local only (git-ignored). Run only when the user asks.
# Tokens are estimates from Devin's session store: "input" = sum of the context size at each model call, before caching, so far above what is billed, "written" = assistant chars/4.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
L=${CREW_LEDGER:-$here/usage/ledger.tsv}
mode=${1:-text}; out=${2:-$here/usage/report.html}
[ -s "$L" ] || { [ "$mode" = hint ] || echo "no usage recorded yet ($L): it fills as crews run"; exit 0; }
exec python3 -I - "$L" "$mode" "$out" <<'PY'
import sys, os, html, datetime as dt
from collections import defaultdict, Counter
L, mode, out = sys.argv[1:4]
turns, qa = [], []
for line in open(L, errors="replace"):
    f = line.rstrip("\n").split("\t")
    try:
        if f[0] == "turn" and len(f) >= 17: turns.append(f)
        elif f[0] == "qa" and len(f) >= 6: qa.append(f)
    except IndexError: pass
if not turns:
    print("ledger has no lane turns yet"); sys.exit(0)
I = lambda s: int(float(s)) if s.replace(".", "", 1).replace("-", "", 1).isdigit() else 0
T = [dict(ts=I(f[1]), proj=f[2], lane=f[3], st=f[4], el=I(f[5]), nud=I(f[6]), res=I(f[7]), cls=f[8],
          peak=I(f[9]), tin=I(f[10]), tout=I(f[11]), tools=I(f[12]), msgs=I(f[13]), acu=float(f[14] or 0), td=I(f[15]), tt=I(f[16])) for f in turns]
name = lambda p: os.path.basename(p.rstrip("/")) or p
# token fields are cumulative per session: keep the latest row per (project, lane); tasks: latest row per project
lastlane, lastproj = {}, {}
for t in sorted(T, key=lambda t: t["ts"]):
    lastlane[(t["proj"], t["lane"])] = t; lastproj[t["proj"]] = t
sess = list(lastlane.values())
mins = sum(t["el"] for t in T) / 60
span_h = max((max(t["ts"] for t in T) - min(t["ts"] - t["el"] for t in T)) / 3600, 1e-9)
tok_in = sum(s["tin"] for s in sess); tok_out = sum(s["tout"] for s in sess)
tasks_done = sum(p["td"] for p in lastproj.values()); tasks_tot = sum(p["tt"] for p in lastproj.values())
ok = sum(t["st"] == "done" for t in T)
byst = Counter(("done" if t["st"] == "done" else "failed(timeout)" if "timeout" in t["st"] else "stalled" if "stalled" in t["st"] else "failed") for t in T)
needs = Counter(t["cls"] for t in T if t["cls"] not in ("-", ""))
byproj = defaultdict(lambda: dict(turns=0, mins=0.0, lanes=set(), fail=0, nud=0, tok=0, td=0, tt=0))
for t in T:
    p = byproj[t["proj"]]; p["turns"] += 1; p["mins"] += t["el"] / 60; p["lanes"].add(t["lane"]); p["fail"] += t["st"] != "done"; p["nud"] += t["nud"]
for s in sess: byproj[s["proj"]]["tok"] += s["tin"] + s["tout"]
for pr, t in lastproj.items(): byproj[pr]["td"], byproj[pr]["tt"] = t["td"], t["tt"]
day = defaultdict(float)
for t in T: day[dt.datetime.fromtimestamp(t["ts"]).strftime("%Y-%m-%d")] += t["el"] / 60
qac = Counter(f[4] for f in qa); qas = Counter(f[5] for f in qa)
k = lambda n: f"{n/1e6:.1f}M" if n >= 1e6 else f"{n/1e3:.0f}k" if n >= 1e3 else str(n)

# ---- fun facts
fun = []
lt = max(T, key=lambda t: t["el"]); fun.append(("Marathoner", f"{lt['lane']} in {name(lt['proj'])} ran {lt['el']/60:.0f} min in one turn"))
nn = max(T, key=lambda t: t["nud"])
if nn["nud"]: fun.append(("Needed a nudge", f"{nn['lane']} in {name(nn['proj'])} stalled and was nudged {nn['nud']}x"))
pk = max(sess, key=lambda s: s["peak"])
if pk["peak"]: fun.append(("Biggest brain", f"{pk['lane']} in {name(pk['proj'])} held {k(pk['peak'])} tokens of context"))
tl = max(sess, key=lambda s: s["tools"])
if tl["tools"]: fun.append(("Busiest hands", f"{tl['lane']} in {name(tl['proj'])} made {tl['tools']} tool calls"))
if day: bd = max(day, key=day.get); fun.append(("Busiest day", f"{bd} with {day[bd]:.0f} lane-minutes"))
owl = sum(1 for t in T if dt.datetime.fromtimestamp(t["ts"]).hour < 6)
if owl: fun.append(("Night shift", f"{owl} turn(s) finished between midnight and 6am"))
fun.append(("Parallelism", f"{mins/60/span_h:.1f} Devins working at once on average over {span_h:.1f}h of crew time"))
if mins: fun.append(("Typing speed", f"~{(tok_out)/mins:.0f} tokens written per lane-minute"))
res = sum(t["res"] for t in T)
if res: fun.append(("Second chances", f"{res} resumed turns (corrections, wake-ups, nudges)"))
streak = best = 0
for t in sorted(T, key=lambda t: t["ts"]):
    streak = streak + 1 if t["st"] == "done" else 0; best = max(best, streak)
fun.append(("Clean streak", f"{best} lane turns in a row ended done"))

if mode == "hint":   # a few lines for the proposal: what earlier crews cost and where they struggled
    import statistics as st
    crews = list(byproj.values())
    mm = st.median(c["mins"] for c in crews); ml = st.median(len(c["lanes"]) for c in crews)
    rough = sum(1 for t in T if t["nud"] or "stalled" in t["st"] or "timeout" in t["st"])
    print(f"history: {len(crews)} earlier crew(s), median {mm:.0f} lane-minutes and {ml:.0f} lane(s) each, biggest {max(c['mins'] for c in crews):.0f} min.")
    print(f"first-try rate: {100*ok/len(T):.0f}% of lane turns ended done; {rough} of {len(T)} needed a nudge or hit a stall/timeout.")
    if needs: print("Devin stopped for the user before: " + ", ".join(f"{a} {b}x" for a, b in needs.most_common(3)) + ".")
    if qac: print("QA found most often: " + ", ".join(f"{a} {b}x" for a, b in qac.most_common(3)) + ".")
    sys.exit(0)

# ---- text
print(f"DEVIN CREW USAGE   {len(byproj)} project(s), {len(lastlane)} lane(s), {len(T)} lane turns")
print(f"time:     {mins:.0f} lane-minutes ({mins/60:.1f} lane-hours); avg turn {mins/len(T):.1f} min; {sum(t['nud'] for t in T)} nudges")
print(f"tokens:   ~{k(tok_in)} input processed (before caching), ~{k(tok_out)} written (estimates); {sum(s['tools'] for s in sess)} tool calls; {sum(s['acu'] for s in sess):.2f} ACU")
print(f"tasks:    {tasks_done}/{tasks_tot} done at each project's last recorded state")
print(f"outcomes: " + ", ".join(f"{a} {b}" for a, b in byst.most_common()) + f"  (success {100*ok/len(T):.0f}%)")
if needs: print("stopped for the user: " + ", ".join(f"{a} {b}" for a, b in needs.most_common()))
if qa: print(f"QA:       {len(qa)} finding(s): " + ", ".join(f"{a} {b}" for a, b in qac.most_common()) + " | " + ", ".join(f"{a} {b}" for a, b in qas.most_common()))
print("projects:")
for pr, p in sorted(byproj.items(), key=lambda x: -x[1]["mins"]):
    print(f"  {name(pr):<22} {len(p['lanes'])} lanes {p['turns']:>3} turns {p['mins']:>6.0f} min  ~{k(p['tok']):>6} tok  tasks {p['td']}/{p['tt']}  failed {p['fail']}  nudges {p['nud']}")
print("fun:")
for a, b in fun: print(f"  {a}: {b}")

if mode != "viz": sys.exit(0)

# ---- html with inline SVG
def bars(items, fmt=lambda v: f"{v:g}", cls=""):
    items = [(a, b) for a, b in items if b > 0]
    if not items: return "<p class=muted>nothing recorded</p>"
    m = max(b for _, b in items); h = 26; w = 520
    s = [f'<svg viewBox="0 0 {w} {h*len(items)+4}" role=img class="{cls}">']
    for i, (a, b) in enumerate(items):
        y = i * h + 2; bw = max(2, (w - 230) * b / m)
        s.append(f'<text x=0 y={y+16} class=lbl>{html.escape(str(a))[:26]}</text><rect x=170 y={y+3} width={bw:.0f} height=16 rx=3 class=bar />'
                 f'<text x={170+bw+6:.0f} y={y+16} class=val>{html.escape(fmt(b))}</text>')
    return "".join(s) + "</svg>"
tiles = [("Projects", len(byproj)), ("Lanes", len(lastlane)), ("Lane turns", len(T)), ("Lane-hours", f"{mins/60:.1f}"),
         ("Input tokens (est, pre-cache)", k(tok_in)), ("Output tokens (est)", k(tok_out)), ("Tool calls", sum(s["tools"] for s in sess)),
         ("Tasks done", f"{tasks_done}/{tasks_tot}"), ("Success", f"{100*ok/len(T):.0f}%")]
days = sorted(day.items())[-30:]
page = f"""<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Devin crew usage</title><style>
:root{{--bg:#fafaf8;--fg:#1c1c1a;--mut:#6b6b66;--card:#fff;--line:#e4e4de;--bar:#2f6fed;--bar2:#c2410c}}
@media(prefers-color-scheme:dark){{:root{{--bg:#151514;--fg:#ecece8;--mut:#9a9a93;--card:#1e1e1c;--line:#33332f;--bar:#6c9bff;--bar2:#f08a55}}}}
body{{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}}main{{max-width:900px;margin:0 auto;padding:24px 16px}}
h1{{font-size:24px;margin:0 0 4px}}h2{{font-size:16px;margin:28px 0 8px}}.muted{{color:var(--mut)}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin-top:16px}}
.tile{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}}.tile b{{display:block;font-size:22px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}}svg{{width:100%;height:auto}}
.lbl,.val{{font-size:12px;fill:var(--fg)}}.val{{fill:var(--mut)}}.bar{{fill:var(--bar)}}.warn .bar{{fill:var(--bar2)}}
table{{width:100%;border-collapse:collapse;font-size:13px}}td,th{{padding:5px 6px;border-bottom:1px solid var(--line);text-align:right}}td:first-child,th:first-child{{text-align:left}}
li{{margin:4px 0}}</style></head><body><main>
<h1>Devin crew usage</h1><p class=muted>{len(byproj)} project(s) · generated {dt.datetime.now():%Y-%m-%d %H:%M} · token numbers are estimates from Devin's session store</p>
<div class=tiles>{"".join(f'<div class=tile><span class=muted>{a}</span><b>{b}</b></div>' for a, b in tiles)}</div>
<h2>Lane-minutes per day</h2><div class=card>{bars([(d, v) for d, v in days], lambda v: f"{v:.0f}")}</div>
<h2>Time by project (minutes)</h2><div class=card>{bars([(name(p), v["mins"]) for p, v in sorted(byproj.items(), key=lambda x: -x[1]["mins"])], lambda v: f"{v:.0f}")}</div>
<h2>Tokens by project (input + output, est., input counted before caching)</h2><div class=card>{bars([(name(p), v["tok"]) for p, v in sorted(byproj.items(), key=lambda x: -x[1]["tok"])], k)}</div>
<h2>How lane turns ended</h2><div class=card>{bars(byst.most_common())}</div>
<h2>Stopped for the user (Devin errors)</h2><div class="card warn">{bars(needs.most_common())}</div>
<h2>What QA found</h2><div class="card warn">{bars(qac.most_common())}</div>
<h2>Projects</h2><div class=card><table><tr><th>project<th>lanes<th>turns<th>min<th>tokens<th>tasks<th>failed<th>nudges</tr>
{"".join(f"<tr><td>{html.escape(name(p))}<td>{len(v['lanes'])}<td>{v['turns']}<td>{v['mins']:.0f}<td>{k(v['tok'])}<td>{v['td']}/{v['tt']}<td>{v['fail']}<td>{v['nud']}</tr>" for p, v in sorted(byproj.items(), key=lambda x: -x[1]['mins']))}</table></div>
<h2>Just for fun</h2><div class=card><ul>{"".join(f"<li><b>{html.escape(a)}</b>: {html.escape(b)}</li>" for a, b in fun)}</ul></div>
</main></body></html>"""
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
open(out, "w").write(page)
print(f"report: {out}")
PY
