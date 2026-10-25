"""A forest's story: the why behind a chapter that already landed.

  GET /landed-why?pr=N   → {pr, sha, subject, body} from the squash commit on origin/main, or 404

A landed PR's branch is gone (the forest contracts as bases land), but its squash commit on main
carries the PR title and body — the chapter's why. Found once per PR and kept: main's history
doesn't change under it.
"""
import json
from urllib.parse import parse_qs

from . import ctx

_FOUND = {}   # (repo, pr) -> answer


def why(req, u):
    raw = parse_qs(u.query).get("pr", [""])[0]
    if not raw.isdigit():
        return req._send(400, json.dumps({"ok": False, "error": "need ?pr=<number>"}))
    key = (ctx.repo_cwd(), int(raw))
    hit = _FOUND.get(key)
    if hit is None:
        r = ctx.run(["git", "log", "origin/main", "-1", "--fixed-strings", f"--grep=(#{raw})", "--format=%h%x1f%s%x1f%b"])
        parts = r.stdout.rstrip("\n").split("\x1f") if r.returncode == 0 and r.stdout.strip() else []
        if len(parts) < 3:
            return req._send(404, json.dumps({"ok": False, "error": f"#{raw} isn't on origin/main yet"}))
        hit = _FOUND[key] = {"ok": True, "pr": int(raw), "sha": parts[0], "subject": parts[1], "body": parts[2].strip()}
    req._send(200, json.dumps(hit))
