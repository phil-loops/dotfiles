#!/usr/bin/env python3
"""A tracker record deleted and recreated under the same id is a new subject: through the real
canopy-todo and canopy-work command lines, against an isolated tracker directory and journal, the
new record gets fresh work with no inherited direction or results; the old conversation's frozen
binding and the old worker's late report can't reach it. Renames keep identity."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import workjournal as wj  # noqa: E402

failures = 0
TMP = tempfile.mkdtemp(prefix="work-incarnation-test-")
ENV = {**os.environ, "CANOPY_TODO_DIR": os.path.join(TMP, "todo"), "CANOPY_WORK_JOURNAL": os.path.join(TMP, "journal.sqlite3")}


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def run(tool, *a, stdin=None):
    p = subprocess.run([sys.executable, os.path.join(HERE, tool), *a], input=stdin, capture_output=True, text=True, env=ENV)
    out = p.stdout.strip()
    return p.returncode, (json.loads(out) if out.startswith(("{", "[")) else out), p.stderr


def add():
    rc, out, err = run("canopy-todo", "add", "Same title", "--kind", "build", "--area", "test", "--why", "fixture", "--id", "same-id")
    assert rc == 0, err
    return open(os.path.join(ENV["CANOPY_TODO_DIR"], "same-id.md")).read()


first = add()
_, w1, _ = run("canopy-work", "work", "--todo", "same-id", "--repo", "dotfiles", "--branch", "feat/same")
W1 = w1["work_id"]
run("canopy-work", "source", "--source", "show", "--adapter", "show-thread")
run("canopy-work", "bind", "--source", "show", "--conversation", "deck#old", "--work", W1, "--by", "test")
rc, cap, err = run("canopy-work", "capture", "--source", "show", "--conversation", "deck#old", "--message-id", "u1", "--seq", "1",
                   stdin="never touch the old route")
run("canopy-work", "cover", "--source", "show", "--conversation", "deck#old", "--through", "1")
check("the first record's instruction is captured for its work", rc == 0 and cap["works"] == {W1: 1}, err)

j = wj.Journal(ENV["CANOPY_WORK_JOURNAL"])
old = j.begin_attempt([W1], worker="fake:old", host="claude-headless", managed=True)
pk = j.prepare(old["attempt_id"])
j.settle_receipt(j.open_receipt(pk["packet_id"], boundary="start"), "acknowledged")
j.report(W1, "progress", "halfway on the old record", via="t", attempt_id=old["attempt_id"], packet_id=pk["packet_id"])
done = j.report(W1, "completion", "finished the old record", via="t", attempt_id=old["attempt_id"], packet_id=pk["packet_id"])
check("the first record earns a current completion", done["verdict"] == "current")

os.remove(os.path.join(ENV["CANOPY_TODO_DIR"], "same-id.md"))
second = add()
inc = lambda text: next(ln for ln in text.splitlines() if ln.startswith("incarnation"))  # noqa: E731
check("the recreated record has its own incarnation", inc(first) != inc(second))
_, w2, _ = run("canopy-work", "work", "--todo", "same-id")
W2 = w2["work_id"]
check("the recreated record gets fresh work", W2 != W1)
_, ctx, _ = run("canopy-work", "context", "--todo", "same-id")
_, st, _ = run("canopy-work", "status", "--todo", "same-id")
check("it inherits no direction", ctx["direction"] == [] and ctx["revision"] == 0 and ctx["latest"] is None)
check("it inherits no results", st["completion"] == "none" and st["last_progress"] is None and st["attempt"] is None)
check("the old record's work is retired, its history kept",
      j.work(W1)["retired_at"] is not None and [m["text"] for m in j.messages(W1)] == ["never touch the old route"]
      and len(j.results(W1)) == 2)

rc, _, err = run("canopy-work", "capture", "--source", "show", "--conversation", "deck#old", "--message-id", "u2", "--seq", "2",
                 stdin="a late reply in the old conversation")
check("the old conversation's frozen binding can't capture into the new record", rc != 0 and "retired" in err and j.messages(W2) == [])
rc, _, err = run("canopy-work", "report", "--work", W1, "completion", "late", "--attempt", old["attempt_id"], "--packet", pk["packet_id"])
check("the old worker's late completion is refused for its retired work", rc != 0 and "retired" in err)
rc, _, err = run("canopy-work", "report", "--todo", "same-id", "completion", "late", "--attempt", old["attempt_id"], "--packet", pk["packet_id"])
check("and can't be redirected onto the new record", rc != 0 and "does not work on" in err and j.results(W2) == [])

run("canopy-work", "relink", "--work", W2, "--branch", "feat/renamed")
_, again, _ = run("canopy-work", "work", "--todo", "same-id")
check("a branch rename keeps the new record's identity", again["work_id"] == W2 and j.work(W2)["branch"] == "feat/renamed")

with open(os.path.join(ENV["CANOPY_TODO_DIR"], "legacy.md"), "w") as f:
    f.write('+++\ntitle = "Old"\nkind = "build"\nstate = "open"\nsize = "S"\n+++\n')
rc, _, err = run("canopy-work", "work", "--todo", "legacy")
check("a legacy record without an incarnation stays unlinked until enrolled", rc != 0 and "enroll" in err)

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
