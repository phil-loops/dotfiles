#!/bin/zsh
# SwiftBar plugin — show: menu-bar launcher for the Show app. The badge counts documents
# waiting on you (unsigned deck sections, unanswered tutor rungs); the menu opens any of
# them in its workspace. Runs lists the live decks Show has opened (Application Support/Show/live-runs.json).
#
# <bitbar.title>Show launcher</bitbar.title>
# <bitbar.desc>Open Show, or jump to a deck or tutor session waiting on you.</bitbar.desc>
# <bitbar.author>phil</bitbar.author>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"
show="$HOME/.dotfiles/scripts/show"

/usr/bin/python3 - "$show" <<'PY'
import json, os, sys, pathlib, time
show = sys.argv[1]
root = pathlib.Path.home() / ".dotfiles/show"
runs = pathlib.Path(os.environ.get("SHOW_LIVE_RUNS") or pathlib.Path.home() / "Library/Application Support/Show/live-runs.json")

def load(p):
    try: return json.loads(p.read_text())
    except Exception: return None

def ago(p):
    s = time.time() - p.stat().st_mtime
    return f"{int(s/60)}m" if s < 3600 else f"{int(s/3600)}h" if s < 86400 else f"{int(s/86400)}d"

groups = {"Forest": [], "Review": [], "Learn": [], "Runs": []}
for p in sorted(root.glob("*.json"), key=lambda p: -p.stat().st_mtime):
    if p.name.endswith((".signoff.json", ".answers.json")): continue
    d = load(p)
    if not d or "sections" not in d or d.get("mode") == "live": continue
    signs = load(p.with_suffix("").with_suffix(".signoff.json")) or {}
    ids = [s.get("id") or s.get("title") for s in d["sections"]]
    left = sum(1 for i in ids if not (signs.get(i) or {}).get("signed"))
    ws = "Forest" if d.get("mode") == "forest" else "Review"
    groups[ws].append((left, f"{d.get('title', p.stem)} — {len(ids)-left} of {len(ids)} signed · {ago(p)}", p))
for p in sorted((root / "tutor").glob("*.json"), key=lambda p: -p.stat().st_mtime):
    if p.name.endswith(".answers.json"): continue
    d = load(p)
    if not d: continue
    answers = load(p.with_suffix("").with_suffix(".answers.json")) or {}
    waiting = 1 if d.get("rungs") and d["rungs"][-1]["id"] not in answers else 0
    groups["Learn"].append((waiting, f"{d.get('title', p.stem)} — {'your turn' if waiting else 'waiting on the tutor'} · {ago(p)}", p))
for r in load(runs) or []:
    p = pathlib.Path(r.get("path", ""))
    d = load(p) if p.is_file() else None
    if not d: continue
    st = d.get("status") or {}
    state = st.get("state") or "?"
    if state == "running" and d.get("runDir") and (pathlib.Path(d["runDir"]) / "STOP").exists():
        state = "stopping"
    count = f" · {st['done']} of {st['total']}" if st.get("done") is not None and st.get("total") is not None else ""
    groups["Runs"].append((state == "failed", f"{d.get('title', p.stem)} — {state}{count} · {ago(p)}", p, state))

waiting = sum(1 for ws, g in groups.items() if ws != "Runs" for left, *_ in g if left)
print(f"{waiting}" if waiting else "", "| sfimage=rectangle.stack")
print("---")
print(f"Open Show | bash={show} terminal=false")
for ws, rows in groups.items():
    if not rows: continue
    print("---")
    print(f"{ws} | size=11 color=gray")
    for left, label, p, *state in sorted(rows, key=lambda r: r[0] == 0)[:8]:
        mark = {"running": "◉", "stopping": "◐", "failed": "◆", "done": "●"}.get(state[0], "○") if state else "◆" if left else "●"
        print(f"{mark} {label} | bash={show} param1={p} terminal=false")
PY
