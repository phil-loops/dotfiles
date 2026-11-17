#!/usr/bin/env python3
"""srv/todo.py's locked read-modify-write: a progress writer holding an old read can't erase input
recorded in between, in one process or across two; `expect` refuses a write over an unseen change.
Runs against a temp tracker directory, never ~/.dotfiles/canopy/todo."""
import os
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import todo  # noqa: E402

failures = 0
TMP = tempfile.mkdtemp(prefix="todo-update-test-")


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def raises(exc, fn):
    try:
        fn()
    except exc as e:
        return e
    return None


todo.DIR = os.path.join(TMP, "todo")
todo.write("item", {"title": "T", "kind": "build", "state": "open", "size": "S"}, "## Next steps\n\nold plan")


def slow_progress():
    def edit(it):
        time.sleep(0.3)   # a long-running progress writer, holding its read
        return {"body": it["body"].replace("old plan", "new plan")}
    todo.update("item", edit=edit)


t = threading.Thread(target=slow_progress)
t.start()
time.sleep(0.05)
todo.update("item", edit=lambda it: {"body": "## Your input\n\n> keep this\n\n" + it["body"]})
t.join()
body = todo.read("item")["body"]
check("progress and input written concurrently both survive", "keep this" in body and "new plan" in body, body)

ver = todo.version("item")
todo.update("item", state="doing")
check("a write based on an old version is refused", isinstance(raises(todo.Stale, lambda: todo.update("item", expect=ver, state="done")), todo.Stale)
      and todo.read("item")["state"] == "doing")
check("a write based on the current version lands", todo.update("item", expect=todo.version("item"), state="waiting", waiting="x")["state"] == "waiting")

xproc = f"""
import sys, time
sys.path.insert(0, {HERE!r})
from srv import todo
todo.DIR = {todo.DIR!r}
def edit(it):
    time.sleep(0.4)
    return {{"body": it["body"] + "\\n\\nprogress from another process"}}
todo.update("item", edit=edit)
"""
p = subprocess.Popen([sys.executable, "-c", xproc])
time.sleep(0.15)
todo.update("item", edit=lambda it: {"body": it["body"] + "\n\n> newest input"})
p.wait()
body = todo.read("item")["body"]
check("the lock holds across processes", "progress from another process" in body and "newest input" in body, body)

print(f"\n{failures} failure(s)" if failures else "\nall passed")
sys.exit(1 if failures else 0)
