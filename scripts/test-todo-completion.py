#!/usr/bin/env python3
"""Every tracker close passes the work journal: canopy-todo done/set/drop and the tracker page's
POST record a completion (unverified unless a cited delivery qualifies) or retire the work, through
the real command line against an isolated tracker directory and journal."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="todo-completion-test-")
os.environ["CANOPY_TODO_DIR"] = os.path.join(TMP, "todo")
os.environ["CANOPY_WORK_JOURNAL"] = os.path.join(TMP, "journal.sqlite3")
sys.path.insert(0, HERE)


class _State:
    @staticmethod
    def poke():
        pass


sys.modules["srv.state"] = _State
from srv import todo, workjournal as wj  # noqa: E402

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def run(*a):
    p = subprocess.run([sys.executable, os.path.join(HERE, "canopy-todo"), *a], capture_output=True, text=True, env=os.environ)
    return p.returncode, p.stdout, p.stderr


def add(item_id):
    rc, _, err = run("add", item_id, "--kind", "build", "--area", "test", "--why", "fixture", "--id", item_id)
    assert rc == 0, err
    return todo.read(item_id)["incarnation"]


rc, _, err = run("add", "No journal yet", "--kind", "build", "--area", "test", "--why", "fixture", "--id", "bare")
rc, _, err = run("done", "bare", "finished")
check("closing without a journal records nothing and creates no journal",
      rc == 0 and "no work recorded" in err and not os.path.exists(os.environ["CANOPY_WORK_JOURNAL"]), err)

j = wj.Journal()
j.register_source("show", adapter="test")


def work_with_delivery(item_id):
    w = j.work_for_todo(item_id, add(item_id), create=True)
    j.bind("show", item_id, [w], by="t")
    j.capture(source="show", conversation=item_id, source_message_id="1", text="do it carefully", source_seq=1)
    j.cover("show", item_id, 1)
    a = j.begin_attempt([w], worker="fake:x", host="claude-headless", managed=True)
    pk = j.prepare(a["attempt_id"])
    j.settle_receipt(j.open_receipt(pk["packet_id"], boundary="start"), "acknowledged")
    return w, a["attempt_id"], pk["packet_id"]


w, att, pk = work_with_delivery("legacy-done")
rc, out, err = run("done", "legacy-done", "looks done")
check("a plain done is recorded, unverified", rc == 0 and "completion unverified" in err and j.status(w)["completion"] == "unverified", err)
check("the tracker still records the reported state", todo.read("legacy-done")["state"] == "done")

w, att, pk = work_with_delivery("cited")
rc, out, err = run("done", "cited", "shipped", "--attempt", att, "--packet", pk)
check("a done citing a qualifying delivery is current", rc == 0 and "completion current" in err and j.status(w)["completion"] == "current", err)
j.capture(source="show", conversation="cited", source_message_id="2", text="one more thing", source_seq=2)
j.cover("show", "cited", 2)
check("new direction after it leaves the tracker saying done but the journal pending",
      todo.read("cited")["state"] == "done" and j.status(w)["completion"] == "historical")

w, att, pk = work_with_delivery("bad-cite")
rc, out, err = run("done", "bad-cite", "x", "--attempt", "a_nonexistent", "--packet", pk)
check("a citation that can't be checked refuses the close entirely", rc != 0 and todo.read("bad-cite")["state"] == "open" and j.results(w) == [], err)

w, att, pk = work_with_delivery("via-set")
rc, out, err = run("set", "via-set", "state=done")
check("set state=done passes the same boundary", rc == 0 and "unverified" in err and j.status(w)["completion"] == "unverified", err)

w, att, pk = work_with_delivery("dropped")
rc, out, err = run("drop", "dropped", "not needed")
check("drop retires the work identity", rc == 0 and "retired" in err and j.work(w)["retired_at"] is not None, err)

with open(os.path.join(os.environ["CANOPY_TODO_DIR"], "old.md"), "w") as f:
    f.write('+++\ntitle = "Old"\nkind = "build"\nstate = "open"\nsize = "S"\n+++\n')
rc, _, err = run("done", "old", "x", "--attempt", att, "--packet", pk)
check("a legacy record can't cite a delivery before it's enrolled", rc != 0 and "enroll" in err and todo.read("old")["state"] == "open", err)
rc, inc1, _ = run("enroll", "old")
rc2, inc2, _ = run("enroll", "old")
check("enroll mints one incarnation and keeps it", rc == 0 and inc1.strip().startswith("i_") and inc1 == inc2)


class Req:
    def _send(self, code, body):
        self.code, self.body = code, json.loads(body)


w, att, pk = work_with_delivery("page")
req = Req()
todo.post(req, json.dumps({"id": "page", "set": {"state": "done"}}))
check("the tracker page's done is recorded, unverified", req.code == 200 and req.body["journal"]["verdict"] == "unverified"
      and j.status(w)["completion"] == "unverified", req.body)
req = Req()
todo.post(req, json.dumps({"id": "page", "set": {"state": "done"}, "expect": "stale0000"}))
check("a stale page write is refused before the journal hears of it", req.code == 409 and len(j.results(w)) == 1)

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
