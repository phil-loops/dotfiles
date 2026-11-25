#!/usr/bin/env python3
"""show-review-join end to end in a scratch folder: a real git repo, a trail, timed utterances, show-note and the clipboard stubbed."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "show-review-join"
NS = 1_000_000_000


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def main():
    failures = []

    def check(name, ok, detail=""):
        print(("✓ " if ok else "✗ ") + name + ("" if ok else f"\n{detail}"))
        if not ok:
            failures.append(name)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        repo = tmp / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "one")
        first = git(repo, "rev-parse", "HEAD")
        git(repo, "branch", "add-lock")
        git(repo, "branch", "use-lock")
        git(repo, "branch", "gone-branch")
        git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "two")
        second = git(repo, "rev-parse", "HEAD")
        git(repo, "branch", "-f", "use-lock", second)

        folder = tmp / "review"
        folder.mkdir()
        t0 = 1_000 * NS
        (folder / "review.json").write_text(json.dumps({
            "title": "lock-user-delete", "scope": "/v2/p/loops/lock-user-delete", "repo": "loops", "repoPath": str(repo),
            "tips": {"add-lock": first, "use-lock": first}}))
        (folder / "recording.json").write_text(json.dumps({"startUptimeNs": t0}))
        trail = [
            {"uptimeNs": t0 - NS, "address": "/v2/p/loops/lock-user-delete", "branch": None, "commit": None},
            {"uptimeNs": t0 + 10 * NS, "address": "/v2/b/loops/add-lock", "branch": "add-lock", "commit": first},
            {"uptimeNs": t0 + 20 * NS, "address": "/v2/b/loops/add-lock?file=models%2Fuser.ts&line=40", "branch": "add-lock", "commit": first},
            {"uptimeNs": t0 + 40 * NS, "address": "/v2/b/loops/use-lock?at=l%7Cqueries%2Fx.ts%7Cn3", "branch": "use-lock", "commit": first},
            {"uptimeNs": t0 + 50 * NS, "address": "/v2/b/loops/use-lock", "branch": "use-lock", "commit": second},
            {"uptimeNs": t0 + 60 * NS, "address": "/v2/b/loops/gone-branch", "branch": "gone-branch", "commit": first},
        ]
        (folder / "trail.jsonl").write_text("".join(json.dumps(e) + "\n" for e in trail))
        git(repo, "branch", "-D", "gone-branch")
        (folder / "utterances.json").write_text(json.dumps({"utterances": [
            {"start": 1, "end": 4, "text": "overall the forest reads well"},
            {"start": 12, "end": 15, "text": "the lock name is vague"},
            {"start": 21, "end": 24, "text": "this select should be for update"},
            {"start": 25, "end": 28, "text": "and it needs a test"},
            {"start": 38, "end": 45, "text": "mostly said on the query file"},
            {"start": 61, "end": 63, "text": "this one got deleted"},
            {"start": 64, "end": 66, "text": "actually back to the whole thing, ship it"},
        ]}))
        sent, copied = tmp / "sent.txt", tmp / "copied.txt"
        note = tmp / "show-note"
        note.write_text(f"#!/bin/sh\nprintf '%s\\n%s' \"$1\" \"$2\" > {sent}\n")
        note.chmod(0o755)
        copy = tmp / "copy"
        copy.write_text(f"#!/bin/sh\ncat > {copied}\n")
        copy.chmod(0o755)
        said = tmp / "said.txt"
        say = tmp / "claude-say"
        say.write_text(f"#!/bin/sh\nprintf '%s\\n%s' \"$1\" \"$2\" > {said}\n")
        say.chmod(0o755)
        git(repo, "config", "stack-project.lock-user-delete.owner", "abcdef12-3456")
        result = subprocess.run([str(SCRIPT), str(folder)], env=dict(os.environ, SHOW_NOTE=str(note), SHOW_REVIEW_COPY=str(copy),
                                SHOW_CLAUDE_SAY=str(say)), capture_output=True, text=True)
        check("runs cleanly", result.returncode == 0, result.stderr)
        notes = (folder / "notes.md").read_text()
        cue = said.read_text()
        check("the forest's owning session gets the cue to act", cue.startswith("abcdef12\n[spoken review] Phil just finished a spoken review of lock-user-delete")
              and f"{folder}/notes.md" in cue, cue)
        check("the Inbox copy says it was sent", "_Sent to the session that owns lock-user-delete" in sent.read_text(), sent.read_text())
        check("posts to the Inbox under the review's name", sent.read_text().startswith("Spoken review · lock-user-delete\n"))
        check("copies the same notes", copied.read_text() == notes)
        check("the forest's own notes come first", notes.index("## The whole review") < notes.index("## [add-lock]"), notes)
        check("a note said before any branch is forest-wide", "- **n1** overall the forest reads well" in notes.split("## [add-lock]")[0], notes)
        check("a note on a branch page with no file sits under the branch", "- **n2** the lock name is vague" in notes, notes)
        check("notes at one file and line run together", "- **n3** `models/user.ts:40` — this select should be for update and it needs a test" in notes, notes)
        check("an utterance goes where it was said longest", "- **n4** `queries/x.ts` — mostly said on the query file" in notes, notes)
        check("a branch that moved mid-review says so", f"changed while you were reviewing it ({first[:8]} → {second[:8]})" in notes, notes)
        check("a note said before the branch moved says the code has changed since",
              f"Moved since you said this: {first[:8]} → {second[:8]}" in notes.split("## [use-lock]")[1].split("##")[0], notes)
        check("a branch still at the commit you saw carries no moved note",
              f"Moved since you said this: {first[:8]} → {second[:8]}" not in notes.split("## [add-lock]")[1].split("##")[0], notes)
        loader = importlib.machinery.SourceFileLoader("join", str(SCRIPT))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader("join", loader))
        loader.exec_module(module)
        place = module.place
        check("a branch name with a slash is the whole name", place("/v2/b/loops/feat/x?file=a.ts&line=3")
              == {"branch": "feat/x", "forest": None, "file": "a.ts", "line": 3})
        records = json.loads((folder / "notes.json").read_text())
        check("each note is numbered in order with its branch and commit", [(n["id"], n["branch"]) for n in records[:4]]
              == [("n1", None), ("n2", "add-lock"), ("n3", "add-lock"), ("n4", "use-lock")] and records[2]["commit"] == first, records)
        check("a deleted branch says it's gone", f"The branch is gone now; you reviewed {first[:8]}" in notes, notes)

        git(repo, "config", "--unset", "stack-project.lock-user-delete.owner")
        subprocess.run([str(SCRIPT), str(folder)], env=dict(os.environ, SHOW_NOTE=str(note), SHOW_REVIEW_COPY=str(copy),
                       SHOW_CLAUDE_SAY=str(say)), check=True)
        check("with no owner, the Inbox copy says nothing picked it up", "_No live session owns lock-user-delete, so nothing picked these up" in sent.read_text())
        git(repo, "branch", "-f", "add-lock", second)
        subprocess.run([str(SCRIPT), str(folder)], env=dict(os.environ, SHOW_NOTE=str(note), SHOW_REVIEW_COPY=str(copy),
                       SHOW_CLAUDE_SAY=str(say)), check=True)
        notes = (folder / "notes.md").read_text()
        check("a branch restacked after the review says what you saw and what's there now",
              f"Moved since you said this: {first[:8]} → {second[:8]}" in notes.split("## [add-lock]")[1].split("##")[0], notes)

    print("all passed" if not failures else f"{len(failures)} failed")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
