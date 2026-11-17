# srv/evidence.py — rendered before/after evidence on a branch page (scripts/evidence_core.py owns
# the records; this module only serves them and starts runs).
#
#   GET  /evidence        ?branch=                → the card: request, latest manifest, whether it
#                                                    matches the branch's current basis, Phil's judgment.
#                                                    Reading a stale card starts its re-capture (see _refresh)
#   GET  /evidence-blob   ?sha=                   → one captured PNG, by content hash
#   POST /evidence-run    {branch, fresh?}        → a run (kind "evidence"); any caller
#   POST /evidence-judge  {manifest, verdict, note?} → Phil's verdict on the manifest he was SHOWN.
#                                                    It names the manifest; nothing is resolved at click time.
import json
import os
import sys
from urllib.parse import parse_qs

from . import ctx, runs

sys.path.insert(0, ctx.SCRIPTS)
import evidence_core as E  # noqa: E402

RUNS_KEPT = 7 * 86_400


def _key(branch):
    return f"{E.repo_name(ctx.repo_cwd())}/{branch}"


def _run_state(branch):
    run = runs.find("evidence", _key(branch))
    if not run:
        return None
    try:
        with open(run.path("out.log")) as f:
            tail = f.read()[-2000:].strip().splitlines()[-6:]
    except OSError:
        tail = []
    return {"running": run.alive(), "exit": run.exit_code(), "started": run.started, "tail": tail}


AUTO = os.path.join(E.CACHE, "auto")


def _subject(card):
    """The state a capture would be of: both trees and the request as it reads now. A sync that
    replays the same patch onto a newer main is a new subject — its before side really is different."""
    req = card.get("request")
    b = E.basis(ctx.repo_cwd(), card["_branch"])
    return E._sha(E._canon({"trees": [b["beforeTree"], b["afterTree"]], "request": req,
                            "recipe": E.recipe_digest(req["recipe"])}))


def _refresh(branch, card):
    """Evidence stays current by itself: a card that's stale (no capture, the branch or its base
    moved, the request changed, or the record predates the current engine) starts a re-capture of
    the current subject — at most one evidence run on the machine at a time, and at most one
    automatic attempt per subject, so a recipe that fails can't loop. Pull, not push: only cards
    someone opens. A judgment needs no re-click when the new pixels are identical (it carries)."""
    if not card.get("request") or (card.get("current") and card.get("eligible") is not False):
        return None
    if any(r.alive() for r in runs.every("evidence")) or E.busy(ctx.repo_cwd()):
        return None
    card["_branch"] = branch
    try:
        subject = _subject(card)
    except E.Refused:
        return None
    mark = os.path.join(AUTO, E._sha(_key(branch).encode()) + ".json")
    if (E._read_json(mark) or {}).get("subject") == subject:
        return None
    E._write_atomic(mark, E._canon({"branch": branch, "subject": subject}))
    try:
        runs.start("evidence", _key(branch), [os.path.join(ctx.SCRIPTS, "evidence"), "run", branch],
                   cwd=ctx.repo_cwd(), meta={"branch": branch, "by": "auto"})
    except runs.Busy:
        return None
    runs.prune("evidence", RUNS_KEPT)
    return subject


def get(req, u):
    branch = (parse_qs(u.query).get("branch") or [""])[0]
    if not branch:
        return req._send(400, json.dumps({"ok": False, "err": "branch is required"}))
    try:
        card = E.card(ctx.repo_cwd(), branch)
    except E.Refused as e:
        return req._send(200, json.dumps({"ok": False, "err": str(e)}))
    auto = _refresh(branch, card)
    card.pop("_branch", None)
    req._send(200, json.dumps({"ok": True, **card, "run": _run_state(branch), "autoStarted": bool(auto)}))


def blob(req, u):
    path = E.blob_path((parse_qs(u.query).get("sha") or [""])[0])
    if not path:
        return req._send(404, "{}")
    with open(path, "rb") as f:
        req._send(200, f.read(), "image/png")


def run(req, raw):
    d = json.loads(raw or "{}")
    branch = d.get("branch", "")
    if not branch:
        return req._send(400, json.dumps({"ok": False, "err": "branch is required"}))
    try:
        if not E.load_request(E.repo_name(ctx.repo_cwd()), branch):
            return req._send(404, json.dumps({"ok": False, "err": f"no evidence request for {branch}"}))
    except E.Refused as e:
        return req._send(400, json.dumps({"ok": False, "err": str(e)}))
    cmd = [os.path.join(ctx.SCRIPTS, "evidence"), "run", branch] + (["--fresh"] if d.get("fresh") else [])
    try:
        runs.start("evidence", _key(branch), cmd, cwd=ctx.repo_cwd(),
                   meta={"branch": branch, "by": getattr(req, "_actor", "")})
    except runs.Busy:
        return req._send(200, json.dumps({"ok": True, "started": True, "already": True}))
    runs.prune("evidence", RUNS_KEPT)
    req._send(200, json.dumps({"ok": True, "started": True}))


def judge(req, raw):
    d = json.loads(raw or "{}")
    try:
        entry = E.judge(d.get("manifest", ""), d.get("verdict", ""), d.get("note", ""),
                        actor=getattr(req, "_actor", "") or "phil")
    except E.Refused as e:
        return req._send(400, json.dumps({"ok": False, "err": str(e)}))
    req._send(200, json.dumps({"ok": True, "at": entry["at"], "verdict": entry["verdict"]}))
