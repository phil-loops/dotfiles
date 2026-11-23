#!/usr/bin/env python3
"""srv/asks.py: one chat per subject, written ahead of its launch; every chat opens with the brief and nothing
else is ever sent; a moved branch is told to its chat; a failed launch leaves nothing; an ask names the code
shown and refuses when the branch moved past it; a corrupt ledger refuses rather than launching a twin. A temp repo, fake launches and panes — no tmux, no claude, no network."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import asks, ctx, reviewdesk, watch  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


REPO = tempfile.mkdtemp(prefix="asks-test-")
ctx.CWD = REPO
ctx.run = lambda argv, timeout=None: subprocess.run(argv, cwd=ctx.repo_cwd(), capture_output=True, text=True, timeout=timeout)


def git(*a):
    return subprocess.run(["git", *a], cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()


def commit(path, text, msg):
    with open(os.path.join(REPO, path), "w") as f:
        f.write(text)
    git("add", path)
    git("commit", "-qm", msg)
    return git("rev-parse", "HEAD")


git("init", "-q")
commit("a.ts", "".join(f"line {i}\n" for i in range(1, 30)), "base")
git("checkout", "-qb", "review/pr-7")
BASE = git("rev-parse", "main")
TIP1 = commit("a.ts", "".join(f"line {i}{' changed' if i == 20 else ''}\n" for i in range(1, 30)), "change")
PR = {"number": 7, "title": "fix: a thing", "author": "nalanj", "body": "why it matters", "base": "main"}
reviewdesk.reviewed = lambda snap=None: {"review/pr-7": PR}
watch._GD.clear()

# ── the world the route acts on, faked: launches, live chats, panes ──
launches, drafts, forwards, live = [], [], [], {}
fail_launch = False
comes_live = True


def fake_launch(branch, session, brief, surface):
    launches.append({"branch": branch, "session": session, "brief": brief, "surface": surface})
    if fail_launch:
        raise asks.Refused("the Claude window didn't open")


REAL_DRAFT = asks._draft_into
asks._launch = fake_launch
asks._draft_into = lambda pane, text: drafts.append((pane, text))
asks._bring_forward = lambda session: forwards.append(session)
asks._refresh_worktree = lambda branch: None
asks.chats.live = lambda session: live.get(session)
def fake_await(session, wait=None):
    if wait == asks.ADOPT_WAIT:   # after a failed launch: alive only if the test made it so
        return live.get(session)
    return live.setdefault(session, {"tmux_pane": "%new"}) if comes_live else None


asks._await_live = fake_await
LEDGER = os.path.join(watch.common_dir(), asks.LEDGER_DIR)


def reset():
    launches.clear(), drafts.clear(), forwards.clear(), live.clear()
    for f in os.listdir(LEDGER) if os.path.isdir(LEDGER) else []:
        os.unlink(os.path.join(LEDGER, f))


def brief(now, sha=None):
    return asks.handle({"branch": "review/pr-7", "kind": "brief", "sha": sha or tip(), "base": BASE}, clock=lambda: now)


def line(now, n=20, sha=None, **kw):
    return asks.handle({"branch": "review/pr-7", "kind": "line", "sha": sha or tip(), "base": BASE, "path": "a.ts", "line": n, **kw}, clock=lambda: now)


def tip():
    return git("rev-parse", "review/pr-7")


def refused(fn):
    try:
        fn()
        return None
    except asks.Refused as e:
        return str(e)


# P5: prompts are pure
b = asks.brief_prompt("review/pr-7", BASE, TIP1, PR)
check("brief names the PR, the exact diff shown, and asks what it's for and the concerns",
      all(x in b for x in ("PR #7", "nalanj", f"git diff {BASE}...{TIP1}", "> why it matters", "What it's for", "Concerns")), b)
check("a brief with no PR names the branch and its purpose", "branch `x` (does y)" in asks.brief_prompt("x", BASE, TIP1, None, "does y"))
check("an author's description is capped", asks.brief_prompt("x", BASE, TIP1, {"number": 1, "body": "z" * 5000}).count("z") == asks.DESCRIPTION_CAP)
check("a line stub ends open for Phil to type", asks.line_prompt("a.ts", "RIGHT", 3, "code", TIP1).endswith("```\n\n"))

# P1: a PR is one subject whichever branch shows it; a branch's work outlives its name; keys never collide
check("a PR is one subject whichever branch shows it", asks.subject("feature-x", PR) == asks.subject("review/pr-7", PR) == "pr:7")
check("a branch with work is its work", asks.subject("old", None, "w_1") == asks.subject("renamed", None, "w_1") == "work:w_1")
check("names that sanitize alike stay distinct subjects", asks.subject_key(asks.subject("feature/a", None)) != asks.subject_key(asks.subject("feature_a", None)))
with open(os.path.join(HERE, "canopy-native/Sources/CanopyCore/Transport/Transport.swift")) as fh:
    patience = int(re.search(r"timeoutIntervalForRequest = (\d+)\b", fh.read()).group(1))
check("the slowest answer (launch + readiness) fits inside canopy's request timeout with room",
      asks.LAUNCH_TIMEOUT + asks.READY_WAIT + 15 <= patience, (asks.LAUNCH_TIMEOUT, asks.READY_WAIT, patience))
check("the grace outlives the slowest launch plus its readiness wait", asks.LAUNCH_GRACE > asks.LAUNCH_TIMEOUT + asks.READY_WAIT)

# every chat opens with the brief, sent — the only thing canopy ever sends
reset()
r = brief(1000)
check("a first brief launches one chat whose first message is the brief", r["reused"] is False and len(launches) == 1 and "Concerns" in launches[0]["brief"], r)
check("…quietly, without taking the screen", launches[0]["surface"] is False and not forwards)
sid = r["session"]

# P2: within the grace a second brief reads "starting", launches nothing, claims nothing
r2 = brief(1010)
check("a brief while it starts says starting", r2.get("starting") and len(launches) == 1 and not forwards, r2)

# a line ask while it starts waits for the chat, then drafts the stub into it
r3 = line(1010)
check("a line ask while it starts waits, then drafts into the chat", r3["reused"] and drafts and drafts[-1][0] == "%new" and len(launches) == 1, (r3, drafts))
check("…the stub carries the shown sha's code at the line", "line 20 changed" in drafts[-1][1] and TIP1[:7] in drafts[-1][1], drafts[-1][1])

# a brief on a live chat only brings it forward
drafts.clear(), forwards.clear()
r4 = brief(1100)
check("a brief on a live chat brings it forward, types nothing", r4["reused"] and forwards == [sid] and not drafts and len(launches) == 1, r4)

# a line ask on a subject with no chat opens one WITH the brief, in front, then drafts the stub
reset()
r5 = line(1200)
check("a first line ask opens a chat that starts with the brief", not r5["reused"] and len(launches) == 1 and "Concerns" in launches[0]["brief"], r5)
check("…in front, with the stub drafted after it is live", launches[0]["surface"] and drafts and "line 20" in drafts[-1][1], drafts)

# P6: an ask names the code shown — the branch past it, or an unknown sha, refuses
check("an ask on a sha the branch has moved past is refused", "moved since" in (refused(lambda: brief(1300, sha=BASE)) or ""))
check("an ask without shas is refused", "doesn't name" in (refused(lambda: asks.handle({"branch": "review/pr-7", "kind": "brief"})) or ""))
check("a line past the file's end is refused", "has 29 lines" in (refused(lambda: line(1300, n=99)) or ""))

# P6: the branch moved since the chat read it — told as a draft once; `told` advances only after delivery
TIP2 = commit("a.ts", "".join(f"line {i}\n" for i in range(1, 30)), "more")
drafts.clear()
real_refresh = asks._refresh_worktree
def failing_refresh(branch):
    raise asks.Refused("couldn't refresh")
asks._refresh_worktree = failing_refresh
check("a move whose refresh fails is refused", refused(lambda: brief(1400)) is not None and not drafts)
asks._refresh_worktree = real_refresh
r6 = brief(1401)
check("…and the move is still owed on the retry", r6["moved"] and drafts and TIP1[:7] in drafts[0][1] and TIP2[:7] in drafts[0][1], (r6, drafts))
drafts.clear()
check("the move is told once", not brief(1410)["moved"] and not drafts)
OTHER_BASE = git("rev-parse", "review/pr-7~1")
drafts.clear()
r6b = asks.handle({"branch": "review/pr-7", "kind": "brief", "sha": tip(), "base": OTHER_BASE}, clock=lambda: 1420)
check("a base-only change is told too", r6b["moved"] and drafts and "different base" in drafts[0][1], (r6b, drafts))
brief(1430)
drafts.clear()

# P2: a gone chat after the grace is stale — the next ask launches a fresh one
live.clear()
r7 = brief(5000)
check("a gone chat's subject launches a new chat", not r7["reused"] and r7["session"] != sid, r7)

# P1/P2: a slow launch can't be superseded — the grace restarts when the launch returns
reset()
t = [0.0]
def slow(*a, **k):
    t[0] += 100
    return fake_launch(*a, **k)
asks._launch = slow
asks.handle({"branch": "review/pr-7", "kind": "brief", "sha": tip(), "base": BASE}, clock=lambda: t[0])
asks._launch = fake_launch
late = asks.LAUNCH_GRACE + 20
r_late = asks.handle({"branch": "review/pr-7", "kind": "brief", "sha": tip(), "base": BASE}, clock=lambda: late)
check("a press past the write-ahead's grace but within the launch's still reads starting", r_late.get("starting") and len(launches) == 1, (r_late, launches))

# a chat that never comes live is refused in words, not claimed
reset()
comes_live = False
check("a line ask whose chat never comes live is refused", "isn't ready" in (refused(lambda: line(5100)) or ""))
comes_live = True

# P8: a failed launch leaves no entry, so the next ask launches again (not "starting")
reset()
fail_launch = True
check("a failed launch is refused", refused(lambda: brief(6000)) is not None)
fail_launch = False
r8 = brief(6001)
check("…and leaves no entry behind", not r8.get("starting") and not r8["reused"] and len(launches) == 2, r8)

# P1/P8: a launch that fails after its chat came up anyway adopts that chat rather than orphaning it
reset()
fail_launch = True
adopt_sid, adopted = [], []
def launch_then_fail(branch, session, brief, surface):
    adopt_sid.append(session)
    live[session] = {"tmux_pane": "%late"}
    fake_launch(branch, session, brief, surface)
asks._launch = launch_then_fail
why = refused(lambda: adopted.append(brief(6200)))
asks._launch = fake_launch
fail_launch = False
check("a launch that failed after its chat came up adopts it", not why and adopted and adopted[0]["session"] == adopt_sid[0], (why, adopted))
r_after = brief(6201)
check("…and the next ask returns to that chat, not a twin", r_after["reused"] and r_after["session"] == adopt_sid[0] and len(launches) == 1, r_after)

# a corrupt entry refuses: never "no chat", never a twin
reset()
brief(6100)
entry = [f for f in os.listdir(LEDGER) if f.endswith(".json")][0]
with open(os.path.join(LEDGER, entry), "w") as f:
    f.write("{not json")
check("a corrupt entry refuses rather than launching", "unreadable" in (refused(lambda: brief(9000)) or "") and len(launches) == 1)
os.unlink(os.path.join(LEDGER, entry))

# P1: an entry whose stored subject isn't the one asked about refuses — a key never silently means two things
reset()
brief(8000)
f = [x for x in os.listdir(LEDGER) if x.endswith(".json")][0]
with open(os.path.join(LEDGER, f)) as fh:
    doc = json.load(fh)
doc["subject"] = "branch:something-else"
with open(os.path.join(LEDGER, f), "w") as fh:
    json.dump(doc, fh)
check("an entry naming another subject refuses", "names another subject" in (refused(lambda: brief(8001)) or "") and len(launches) == 1)

# P1 under interleaving: two presses decide at the same moment — exactly one chat. standing() is slowed
# so both requests sit in the read→decide window together; only the subject's lock keeps them apart.
reset()
real_standing = asks.standing
asks.standing = lambda entry, now, live=None: (time.sleep(0.3), real_standing(entry, now))[1]
results = []
threads = [threading.Thread(target=lambda: results.append(brief(7000))) for _ in range(2)]
[t.start() for t in threads]
[t.join(10) for t in threads]
asks.standing = real_standing
check("two presses at once: one chat, the other reads starting",
      len(launches) == 1 and sorted(bool(x.get("starting")) for x in results) == [False, True], (launches, results))

# P6 under interleaving: two asks on different bases type into one chat at once — `told` matches the last paste
reset()
r0 = brief(9100)
live[r0["session"]] = {"tmux_pane": "%5"}
pasted, held = [], []
def watching_paste(pane, text):
    # the principle itself: a paste happens while this subject's lock is held
    with open([os.path.join(LEDGER, f) for f in os.listdir(LEDGER) if f.endswith(".lock")][0]) as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lk, fcntl.LOCK_UN)
            held.append(False)
        except BlockingIOError:
            held.append(True)
    pasted.append(text)
asks._draft_into = watching_paste
other = git("rev-parse", "review/pr-7~1")
asks.handle({"branch": "review/pr-7", "kind": "brief", "sha": tip(), "base": other}, clock=lambda: 9101)
asks._draft_into = lambda pane, text: drafts.append((pane, text))
with open([os.path.join(LEDGER, f) for f in os.listdir(LEDGER) if f.endswith(".json")][0]) as fh:
    told_base = json.load(fh)["told"][0]
check("a delivery pastes under its subject's lock, so concurrent asks can't reorder told against pastes",
      held == [True] and told_base == other, (held, told_base[:7]))

# each paste owns its tmux buffer, and nothing it does presses Enter
calls = []
real_run = asks.subprocess.run
asks.subprocess.run = lambda argv, **kw: calls.append(argv) or subprocess.CompletedProcess(argv, 0, "", "")
REAL_DRAFT("%1", "a"), REAL_DRAFT("%2", "b")
asks.subprocess.run = real_run
bufs = [a[a.index("-b") + 1] for a in calls if "-b" in a]
check("each paste loads and pastes its own buffer", len(set(bufs)) == 2 and all(bufs.count(b) == 2 for b in set(bufs)), calls)
check("…as a bracketed paste, never a send", all("send-keys" not in a for a in calls) and all("-p" in a for a in calls if "paste-buffer" in a), calls)

# P4: every chat runs under the deny settings — tripwires on the two places that could silently drop them
with open(os.path.join(HERE, "stack-claude")) as f:
    runs = [ln for ln in f if ln.strip().startswith('run="claude')]
check("every way stack-claude starts claude passes the settings flag", runs and all("${settings_flag}" in ln for ln in runs), runs)
with open(asks.ASK_SETTINGS) as f:
    deny = set(json.load(f)["permissions"]["deny"])
OUTWARD = ["git push", "gh api", "gh comment", "gh review", "gh edit", "gh merge", "gh create", "gh delete", "gh reopen", "gh auth token"]
missing = [f"{v}: {form}" for v in OUTWARD for tool, word in [v.split(" ", 1)]
           for lead in ("", "* ") for mid in (" ", " * ") for form in (f"Bash({lead}{tool}{mid}{word} *)", f"Bash({lead}{tool}{mid}{word})")
           if form not in deny]
check("each outward verb is denied as a whole word: first or after flags, alone or after another command", not missing, missing)

# a malformed ask answers 400, not a crash
class Req:
    def _send(self, code, body):
        self.code, self.body = code, body


q = Req()
asks.ask(q, "[1]")
check("a non-object body answers 400", q.code == 400, q.__dict__)
asks.ask(q, '{"branch":"review/pr-7","kind":"line","sha":"%s","base":"%s","path":"a.ts","line":"x"}' % (tip(), BASE))
check("a non-number line answers 400", q.code == 400, q.__dict__)
asks.ask(q, '{"branch":"nope","kind":"brief","sha":"%s","base":"%s"}' % (tip(), BASE))
check("an unknown branch is refused in words", q.code == 200 and '"ok": false' in q.body and "no branch nope" in q.body, q.body)

print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
