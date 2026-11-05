#!/usr/bin/env python3
"""show-job end to end in a scratch folder: set twice, then done and fail, with show-note stubbed."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "show-job"


def run(env, *args):
    return subprocess.run([str(SCRIPT), *args], env=env, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        notes = tmp / "notes.txt"
        stub = tmp / "show-note"
        stub.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$1\" >> {notes}\n")
        stub.chmod(0o755)
        env = dict(os.environ, SHOW_JOBS=str(tmp / "jobs"), SHOW_LIVE_RUNS=str(tmp / "runs.json"), SHOW_NOTE=str(stub))
        failures = []

        def check(name, ok, detail=""):
            print(("✓ " if ok else "✗ ") + name + ("" if ok else f"  {detail}"))
            if not ok:
                failures.append(name)

        assert run(env, "set", "a", "--title", "Eval", "--row", "e4b 10/100 warm", "--line", "disk 40%").returncode == 0
        assert run(env, "set", "a", "--title", "Eval", "--row", "e4b 20/100 warm", "--line", "disk 41%").returncode == 0
        deck = json.loads((tmp / "jobs/a.json").read_text())
        state = json.loads((tmp / "jobs/a.job.json").read_text())
        check("a set writes a live deck with a long stale window", deck["mode"] == "live" and deck["staleAfter"] == 600)
        check("status sums the rows", deck["status"] == {"state": "running", "done": 20, "total": 100, "current": "e4b"}, deck["status"])
        check("readings accumulate per row", [r[1] for r in state["rows"][0]["readings"]] == [10, 20], state["rows"][0])
        check("the job is registered once", len(json.loads((tmp / "runs.json").read_text())) == 1)
        check("a row without done/total is refused", run(env, "set", "a", "--title", "Eval", "--row", "e4b").returncode != 0)
        check("no Inbox note while running", not notes.exists())

        assert run(env, "done", "a", "--note", "all models finished").returncode == 0
        deck = json.loads((tmp / "jobs/a.json").read_text())
        check("done marks the deck done", deck["status"]["state"] == "done")
        check("done posts one Inbox note", notes.read_text().splitlines() == ["Job finished: Eval"], notes.read_text())
        run(env, "done", "a")
        check("a second done posts nothing", len(notes.read_text().splitlines()) == 1)

        run(env, "set", "b", "--title", "Backfill", "--row", "1/5")
        check("fail needs a note", run(env, "fail", "b").returncode != 0)
        run(env, "fail", "b", "--note", "worker exited 137")
        deck = json.loads((tmp / "jobs/b.json").read_text())
        check("fail gives the reason as current", deck["status"]["state"] == "failed" and deck["status"]["current"] == "worker exited 137", deck["status"])
        check("fail posts its note", notes.read_text().splitlines()[-1] == "Job failed: Backfill")
        run(env, "set", "b", "--title", "Backfill", "--row", "0/5")
        state = json.loads((tmp / "jobs/b.job.json").read_text())
        check("a set after the end starts a fresh run", state["state"] == "running" and len(state["rows"][0]["readings"]) == 1)
        check("a done of an unknown job is refused", run(env, "done", "nope").returncode != 0)
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
