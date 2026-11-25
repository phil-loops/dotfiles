#!/usr/bin/env python3
"""stack-attention in a scratch repo: add, refuse what isn't pithy, go stale when the tip moves, sign off, clear one's own."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "stack-attention"


def main():
    failures = []

    def check(name, ok, detail=""):
        print(("✓ " if ok else "✗ ") + name + ("" if ok else f"\n{detail}"))
        if not ok:
            failures.append(name)

    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)

        def git(*args):
            return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                                  capture_output=True, text=True, check=True).stdout.strip()

        def run(*args, session="aaaaaaaa-1"):
            env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "TMUX_PANE")
                   and not k.startswith("CODEX_")}
            env["STACK_ATTENTION_REPO"] = str(repo)
            if session:
                env["CLAUDE_CODE_SESSION_ID"] = session
            return subprocess.run([str(SCRIPT), *args], env=env, capture_output=True, text=True)

        git("init", "-q", "-b", "main")
        git("commit", "-q", "--allow-empty", "-m", "base")
        for b in ("notify", "owners", "loose"):
            git("branch", b)
        git("config", "branch.notify.stack-project", "notices")
        git("config", "branch.owners.stack-project", "notices")

        first = run("add", "notify", "models/x.ts:40", "look", "Notify now reads top to bottom; check the steps read right.")
        check("an item is added and its id printed", first.returncode == 0 and first.stdout.startswith("a-"), first.stderr)
        item = json.loads(run("ls", "notices", "--json").stdout)[0]
        check("it keeps the place, the ask and the tip", (item["branch"], item["file"], item["line"], item["ask"], item["state"])
              == ("notify", "models/x.ts", 40, "look", "fresh") and item["tip"] == git("rev-parse", "notify"), item)
        check("a file without a line is a file", json.loads(run("ls", "--json").stdout)[0]["file"] == "models/x.ts"
              and run("add", "owners", "lib/a.ts", "decide", "Merging this turns customer emails on.").returncode == 0)
        check("a long sentence is refused", run("add", "notify", "-", "look", "x" * 161).returncode == 2)
        check("an unknown ask is refused", run("add", "notify", "-", "review", "short").returncode == 2)
        check("a branch outside a forest is refused", run("add", "loose", "-", "look", "short").returncode == 2)
        for n in range(3):
            run("add", "notify", "-", "look", f"item {n}")
        check("a sixth open item on a forest is refused", run("add", "notify", "-", "look", "one too many").returncode == 2)
        git("checkout", "-q", "notify")
        git("commit", "-q", "--allow-empty", "-m", "moves")
        states = {i["id"]: i["state"] for i in json.loads(run("ls", "notices", "--json").stdout)}
        check("an item goes stale when its branch tip moves", states[first.stdout.strip()] == "stale", states)
        check("an agent can't sign off for Phil", run("done", first.stdout.strip(), "--by", "phil").returncode == 2)
        check("an agent can't retract another session's item", run("done", first.stdout.strip(), session="bbbbbbbb-2").returncode == 2)
        check("outside an agent session there's no writer to add as", run("add", "notify", "-", "look", "short", session=None).returncode == 2)
        run("done", first.stdout.strip(), "--by", "phil", session=None)
        check("Phil's sign-off from canopy (no agent session) takes the item off the list", first.stdout.strip() not in run("ls", "notices").stdout)
        done = [i for i in json.loads(Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"), "stack-attention.json").read_text())["items"]
                if i["id"] == first.stdout.strip()][0]["done"]
        check("the sign-off is recorded as Phil's", done["by"] == "phil", done)
        mine = run("add", "owners", "-", "look", "retract me").stdout.strip()
        check("a writer can retract its own item", run("done", mine).returncode == 0 and mine not in run("ls").stdout)
        run("add", "owners", "-", "act", "another session's item", session="bbbbbbbb-2")
        run("clear", "notices", "--mine")
        left = json.loads(run("ls", "notices", "--json").stdout)
        check("clear --mine leaves other sessions' items", [i["text"] for i in left] == ["another session's item"], left)

    print("all passed" if not failures else f"{len(failures)} failed")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
