#!/usr/bin/env python3
"""show-review-reply end to end: a scratch forest reviewed, rebuilt (one branch's change kept, one changed, one new, one
gone), then a plan and answers rendered with show-note stubbed."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "show-review-reply"


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

        def git(*args):
            return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                                  capture_output=True, text=True, check=True).stdout.strip()

        def commit(branch, files, message):
            if subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "-q", "HEAD"], capture_output=True).returncode == 0:
                git("checkout", "-q", branch)
            for name, text in files.items():
                (repo / name).write_text(text)
            git("add", "-A")
            git("commit", "-q", "-m", message)
            return git("rev-parse", "HEAD")

        git("init", "-q", "-b", "main")
        commit("main", {"base.txt": "base\n"}, "base")
        git("branch", "kept")
        kept_then = commit("kept", {"kept.txt": "kept\n"}, "kept")
        git("branch", "fixed")
        fixed_then = commit("fixed", {"fixed.txt": "first try\n"}, "fixed")
        git("branch", "gone")
        commit("gone", {"gone.txt": "gone\n"}, "gone")
        for b, p in [("kept", "main"), ("fixed", "kept"), ("gone", "fixed")]:
            git("config", f"branch.{b}.stack-parent", p)
            git("config", f"branch.{b}.stack-project", "f")

        folder = tmp / "review"
        folder.mkdir()
        (folder / "review.json").write_text(json.dumps({
            "title": "f", "scope": "/v2/p/loops/f", "repo": "loops", "repoPath": str(repo),
            "tips": {"kept": kept_then, "fixed": fixed_then, "gone": git("rev-parse", "gone")},
            "parents": {"kept": "main", "fixed": "kept", "gone": "fixed"}}))
        (folder / "notes.json").write_text(json.dumps([
            {"id": "n1", "branch": "kept", "file": "kept.txt", "line": 1, "commit": kept_then, "text": "looks right"},
            {"id": "n2", "branch": "fixed", "file": "fixed.txt", "line": 1, "commit": fixed_then, "text": "rename it, and split it"},
        ]))

        commit("main", {"main2.txt": "main moved\n"}, "main moves")
        git("checkout", "-q", "kept")
        git("rebase", "-q", "main")
        git("checkout", "-q", "fixed")
        git("reset", "-q", "--hard", "kept")
        commit("fixed", {"fixed.txt": "second try\n"}, "fixed again")
        git("branch", "-D", "gone")
        git("branch", "owners", "fixed")
        commit("owners", {"owners.txt": "owners\n"}, "owners")
        git("config", "branch.owners.stack-parent", "fixed")
        git("config", "branch.owners.stack-project", "f")

        sent = tmp / "sent.txt"
        note = tmp / "show-note"
        note.write_text(f"#!/bin/sh\nprintf '%s\\n%s' \"$1\" \"$2\" > {sent}\n")
        note.chmod(0o755)
        env = dict(os.environ, SHOW_NOTE=str(note))

        (folder / "plan.txt").write_text("# structure\nowners | fixed | new | split out of fixed (n2)\n"
                                         "# notes\nn1 | no ask | - | heard: fine as is\nn2a | will do | - | heard: rename → call it fixed-name\n")
        subprocess.run([str(SCRIPT), str(folder)], env=env, check=True)
        plan = (folder / "plan.md").read_text()
        check("with only a plan, the plan is what's shown", sent.read_text().startswith("Plan for your review · f\n"), sent.read_text())
        check("the plan lists the rough shape", "- **owners** on fixed · new — split out of fixed (n2)" in plan, plan)
        check("each note shows how it was heard", "**n2a will do** — heard: rename → call it fixed-name" in plan, plan)
        check("a note the plan answers carries no warning", plan.count("⚠ _no answer_") == 0, plan)

        (folder / "answers.txt").write_text("# structure\nowners | fixed | new | split out of fixed (n2)\ngone | - | removed | folded into fixed\n"
                                            "# notes\nn1 | no ask | - | liked\nn2a | done | abc12345 | renamed\nn2b | declined | - | one file is enough\n")
        subprocess.run([str(SCRIPT), str(folder)], env=env, check=True)
        since = (folder / "since.md").read_text()
        look = since.split("## Look at")[1].split("\n## ")[0]
        check("with answers, the since view is shown", sent.read_text().startswith("Since your review · f\n"), sent.read_text())
        check("a branch rebased with the same change is the change you read", "Same change you read" in since.split("## [kept]")[1].split("\n## ")[0], since)
        check("a branch whose change you read stays out of Look at", "kept" not in look, look)
        check("a changed branch says what moved and that you asked", "[fixed](canopy://v2/b/loops/fixed) — changed, you asked: n2a" in look
              and "changed `fixed.txt`" in since, since)
        check("a declined ask is in Look at", "**n2b declined**: one file is enough" in look, look)
        check("a new branch is in Look at with its reason", "[owners](canopy://v2/b/loops/owners) — new: split out of fixed (n2)" in look, look)
        check("a gone branch is in Look at with its reason", "- gone — gone: folded into fixed" in look, look)
        check("--plan still shows the plan once answers exist",
              subprocess.run([str(SCRIPT), "--plan", str(folder)], env=env).returncode == 0 and sent.read_text().startswith("Plan for your review"))

    print("all passed" if not failures else f"{len(failures)} failed")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
