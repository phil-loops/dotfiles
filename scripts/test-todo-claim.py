#!/usr/bin/env python3
"""canopy-todo claim records the forest branch it was claimed from as solved_by, so the home can mark that
branch's dot. Runs against a temp tracker and a throwaway repo, never ~/.dotfiles/canopy/todo."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="todo-claim-test-")
REPO = os.path.join(TMP, "repo")
SID = "feedface-0000-4000-8000-000000000001"
ENV = {**os.environ, "CANOPY_TODO_DIR": os.path.join(TMP, "todo"), "CLAUDE_CODE_SESSION_ID": SID,
       "CANOPY_WORK_JOURNAL": os.path.join(TMP, "journal.sqlite3")}
os.makedirs(ENV["CANOPY_TODO_DIR"])
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def run(*args, cwd=REPO):
    return subprocess.run(args, cwd=cwd, env=ENV, capture_output=True, text=True, check=True).stdout.strip()


def todo(*args):
    return run(os.path.join(HERE, "canopy-todo"), *args)


def solved_by(item):
    return next((line.split("=", 1)[1].strip().strip('"') for line in todo("show", item).splitlines() if line.startswith("solved_by")), None)


run("git", "init", "-q", "-b", "main", REPO, cwd=TMP)
run("git", "commit", "-q", "--allow-empty", "-m", "root")
run("git", "switch", "-q", "-c", "feat/a")
run("git", "config", "branch.feat/a.stack-project", "fx")
run("git", "switch", "-q", "-c", "loose")

for item, project in [("viewer-item", None), ("forest-item", "repo:fx"), ("other-forest-item", "repo:other"), ("loose-item", None), ("bound-item", None)]:
    todo("add", item, "--kind", "build", "--area", "x", "--why", "w", *(["--project", project] if project else []))
todo("set", "bound-item", "solved_by=feat/kept")

todo("claim", "loose-item")
check("a branch outside any forest records nothing", solved_by("loose-item") is None, solved_by("loose-item"))

run("git", "switch", "-q", "feat/a")
for item in ["viewer-item", "forest-item", "other-forest-item", "bound-item"]:
    todo("claim", item)
check("a viewer item claimed on a forest branch records it", solved_by("viewer-item") == "feat/a", solved_by("viewer-item"))
check("an item on that forest's own list records it", solved_by("forest-item") == "feat/a", solved_by("forest-item"))
check("an item on another forest's list records nothing", solved_by("other-forest-item") is None, solved_by("other-forest-item"))
check("an existing solved_by is kept", solved_by("bound-item") == "feat/kept", solved_by("bound-item"))

run("git", "switch", "-q", "--detach")
todo("add", "detached-item", "--kind", "build", "--area", "x", "--why", "w")
todo("claim", "detached-item")
check("a detached HEAD records nothing", solved_by("detached-item") is None, solved_by("detached-item"))

sys.path.insert(0, HERE)
from srv import todo as T, workjournal as wj  # noqa: E402
T.DIR = ENV["CANOPY_TODO_DIR"]
j = wj.Journal(ENV["CANOPY_WORK_JOURNAL"])
work = j.work_for_todo("forest-item", T.read("forest-item")["incarnation"])
check("a claim binds this chat, by its full id, to the item's work", work is not None
      and work in j.bound_works("claude-code", SID), (work, j.bound_works("claude-code", SID)))
check("the claim's branch is the work's label", (j.work(work) or {}).get("branch") == "feat/a", j.work(work))
check("every claim adds; none switches the chat away", len(j.bound_works("claude-code", SID)) == 6, j.bound_works("claude-code", SID))
j.close()

OTHER = {**ENV, "CLAUDE_CODE_SESSION_ID": "feedface"}
todo("add", "short-id-item", "--kind", "build", "--area", "x", "--why", "w")
r = subprocess.run([os.path.join(HERE, "canopy-todo"), "claim", "short-id-item"], cwd=REPO, env=OTHER, capture_output=True, text=True)
check("a chat without a full id is assigned and says it isn't bound", r.returncode == 0 and "doing" in r.stdout
      and "not bound" in r.stderr, (r.returncode, r.stdout, r.stderr))

sys.exit(1 if failures else 0)
