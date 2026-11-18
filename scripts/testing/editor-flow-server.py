#!/usr/bin/env python3
"""Serve a disposable editor flow through the production Git readers and write routes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root")
    parser.add_argument("--refresh-delay", type=float, default=0)
    parser.add_argument("--source-repo")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    repo = root / "repo"
    repo.mkdir(parents=True)
    branch = "editor-flow"

    def git(*argv):
        return subprocess.run(["git", "-C", str(repo), *argv], capture_output=True, text=True, check=True).stdout.strip()

    if args.source_repo:
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", args.source_repo, str(repo)], check=True)
    else:
        git("init", "-q", "-b", "main")
    for key, value in {"user.name": "Editor flow", "user.email": "editor-flow@example.invalid",
                       "commit.gpgsign": "false", "core.hooksPath": str(repo / ".git/hooks")}.items():
        git("config", key, value)
    if args.source_repo:
        source_tip = subprocess.check_output(["git", "-C", args.source_repo, "rev-parse", "HEAD"], text=True).strip()
        git("checkout", "-q", "-B", "main", source_tip)
        if (repo / "a.txt").exists():
            raise RuntimeError("source repository already has the fixture's a.txt")
        for name in ("node_modules", ".gen"):
            source = Path(args.source_repo) / name
            if source.exists() and not (repo / name).exists():
                (repo / name).symlink_to(source, target_is_directory=True)
    (repo / "a.txt").write_text("original\n")
    git("add", "a.txt")
    git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD")
    git("checkout", "-qb", branch)
    (repo / "a.txt").write_text("before\n")
    git("commit", "-qam", "feat: edit a file")
    initial = git("rev-parse", "HEAD")
    git("config", f"branch.{branch}.stack-parent", "main")
    git("config", f"branch.{branch}.stack-project", branch)
    git("config", f"stack-project.{branch}.branch", branch)
    with (repo / ".git/info/exclude").open("a") as out:
        out.write("\n.gen\nnode_modules\n")
    os.environ["STACK_OPEN_DIR"] = str(root / "scratch")
    os.environ["STACK_OPEN_NO_REAP"] = "1"
    os.environ["STACK_OPEN_NO_GEN_SYNC"] = "1"
    os.environ["STACK_REVIEW_GH_FAKE"] = str(root / "github.json")
    (root / "github.json").write_text('{"viewer":"editor-flow","prs":{}}')
    from srv import ctx, edits, repostate, review, routes, state
    ctx.CWD = ctx.MAIN_WT = str(repo)
    ctx.SCRIPTS = str(SCRIPTS)
    ctx.REPOS = {"loops": str(repo)}
    ctx.run = lambda argv, timeout=None: subprocess.run(argv, cwd=ctx.repo_cwd(), capture_output=True, text=True, timeout=timeout)
    epoch = "editor-flow-" + root.name
    state.EPOCH = epoch
    condition = threading.Condition()
    updates = []
    writes = 0
    requests = []
    git_calls = []
    phase = threading.local()
    run = subprocess.run

    def measured(argv, *args, **kwargs):
        started = time.perf_counter()
        try:
            return run(argv, *args, **kwargs)
        finally:
            stage = getattr(phase, "stage", "") or "background"
            if argv and Path(argv[0]).name == "git":
                git_calls.append({"phase": stage, "argv": [str(arg) for arg in argv],
                                  "ms": (time.perf_counter() - started) * 1000})

    subprocess.run = measured

    def branch_entity():
        tip = git("rev-parse", branch)
        outline = git("log", "--reverse", "--format=%s", f"main..{tip}").splitlines()
        return {"id": f"loops:{branch}", "repo": "loops", "name": branch, "project": f"loops:{branch}",
                "parent": "main", "description": "Edit transaction", "subject": outline[-1], "commits": len(outline),
                "outline": outline, "tip": tip, "tree": git("rev-parse", f"{tip}^{{tree}}"),
                "pushed": "local", "ahead": 0, "gates": "none", "redGates": [], "order": 1,
                "behind": 0, "drifted": False, "upstream": "", "upstreamBad": False, "diverged": False}

    def publish():
        nonlocal writes
        time.sleep(args.refresh_delay)
        entity = branch_entity()
        with condition:
            updates.append({"domain": "git", "version": len(updates) + 2, "asOf": writes,
                            "upserts": {"branch": {entity["id"]: entity}}, "deletes": {}})
            condition.notify_all()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype="application/json"):
            nonlocal writes
            if isinstance(body, str):
                body = body.encode()
            if self.command == "POST" and self.path.endswith(("/edit-session", "/edit-commit")):
                print(self.path, code, body.decode(), flush=True)
            if self.command == "POST" and self.headers.get("X-Stack-Write") and code == 200:
                data = json.loads(body)
                if data.get("ok"):
                    with condition:
                        writes += 1
                        data["wrote"] = writes
                    body = json.dumps(data).encode()
                    threading.Thread(target=publish, daemon=True).start()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            ctx.set_repo(str(repo))
            u = urlparse(self.path)
            requests.append({"method": "GET", "path": u.path})
            try:
                if u.path == "/state":
                    entity = branch_entity()
                    state = {"epoch": epoch, "versions": {"git": 1, "remote": 1, "review": 1, "todo": 1},
                             "entities": {"repo": {"loops": {"id": "loops", "name": "loops", "main": "main", "trunk": base}},
                                          "project": {f"loops:{branch}": {"id": f"loops:{branch}", "repo": "loops", "name": branch,
                                                                            "state": "workbench", "summary": "Editor flow", "size": 1}},
                                          "branch": {entity["id"]: entity}}}
                    return self._send(200, json.dumps(state))
                if u.path == "/v2":
                    return self._send(200, '<script>window.__VIEWER_REPOS__=["loops"];window.__CANOPY_KEYS__={"keys":{},"errors":[]};window.__CANOPY_ASSET__="editor-flow"</script>', "text/html")
                if u.path == "/v2/events":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    self.wfile.write(("event: hello\ndata: " + json.dumps({"epoch": epoch, "asset": "editor-flow"}) + "\n\n").encode())
                    self.wfile.flush()
                    sent = 0
                    while True:
                        with condition:
                            condition.wait_for(lambda: len(updates) > sent, timeout=1)
                            batch = updates[sent:]
                            sent = len(updates)
                        for patch in batch:
                            self.wfile.write(("event: patch\ndata: " + json.dumps(patch) + "\n\n").encode())
                        if not batch:
                            self.wfile.write(b": alive\n\n")
                        self.wfile.flush()
                if u.path == "/loops/node":
                    return review.node(self, u)
                if u.path == "/loops/commits":
                    return review.commits(self, u)
                if u.path == "/loops/file":
                    return review.file(self, u)
                if u.path == "/test/result":
                    (root / "git-calls.json").write_text(json.dumps(git_calls, indent=2))
                    return self._send(200, json.dumps({"tip": git("rev-parse", branch), "initial": initial,
                                                        "count": int(git("rev-list", "--count", "main.." + branch)),
                                                        "text": git("show", f"{branch}:a.txt"), "requests": requests,
                                                        "parkedTip": json.loads((repo / ".git/canopy-edits/ready.json").read_text()).get("tip") if (repo / ".git/canopy-edits/ready.json").exists() else None}))
                if u.path == "/review-requests":
                    return self._send(200, "[]")
                return self._send(200, "{}")
            finally:
                ctx.clear_repo()

        def do_POST(self):
            ctx.set_repo(str(repo))
            path = urlparse(self.path).path
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
            requests.append({"method": "POST", "path": path, "body": json.loads(raw or "{}")})
            self._actor = "browser"
            phase.stage = path
            try:
                if path in ("/loops/review-helix", "/loops/edit-session", "/loops/edit-commit", "/loops/edit-warm",
                            "/loops/edit-workspaces", "/loops/edit-recover"):
                    return routes.post(self, path.removeprefix("/loops"), raw)
                if path == "/test/recover-last":
                    tip = git("rev-parse", branch)
                    saved = [(file.parent, edits._load(file.parent)) for file in (repo / ".git/canopy-edits").glob("*/session.json")]
                    saved = [(directory, value) for directory, value in saved if value.get("kind") == "editor" and value.get("receipt", {}).get("sha") == tip]
                    if len(saved) != 1:
                        raise RuntimeError("the fixture needs exactly one saved operation at its current tip")
                    directory, value = saved[0]
                    value["state"] = "landing"
                    edits._save(directory / "session.json", value)
                    return self._send(200, json.dumps({"ok": True, "sha": tip, "operation": value["operation"]}))
                if path == "/loops/syntax/units":
                    return self._send(200, '{"ok":true,"units":[],"functions":[],"classes":[]}')
                return self._send(200, '{"ok":true}')
            finally:
                phase.stage = ""
                repostate.invalidate()
                ctx.clear_repo()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    (root / "server.json").write_text(json.dumps({"port": server.server_port, "epoch": epoch, "repo": str(repo)}))
    server.serve_forever()


if __name__ == "__main__":
    main()
