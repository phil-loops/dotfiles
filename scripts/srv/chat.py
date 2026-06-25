# srv/chat.py — "chat about this file", streamed into the browser. Runs a headless,
# READ-ONLY `claude -p` in the branch's worktree and proxies its stream-json output to
# the page as Server-Sent Events, so answer tokens land live instead of all-at-once.
# Multi-turn is stateless here: the client keeps the session_id we report (at stream start,
# repeated on `done`) and sends it back as `resume` for the next turn (so follow-ups keep the file
# context without us re-sending the diff).
#
#   POST /chat {branch, path?, patch?, question, resume?}  → text/event-stream
#     (omit path → chat about the whole branch; the server computes its parent…branch diff)
#     event: session data: {"session_id":"…"}        # sent ASAP so a cut-short chat resumes
#     event: status data: {"s":"starting|thinking|writing"}
#     event: token  data: {"t":"…"}                  # an answer text delta
#     event: done   data: {"ok":true,"session_id":"…"}
#     event: error  data: {"err":"…"}
#
# Safety: an allowlist of read-only tools (Read/Grep/Glob) — headless claude can't prompt
# for anything outside it, so it can look around the branch but never edit/run/commit. The
# whole claude runs in its own process group; if the browser closes the stream we SIGKILL
# the group so no headless session lingers.
import os
import json
import signal
import subprocess
import threading
import time

from . import ctx, prompts


def tmux_targets(req):   # GET /tmux-targets — existing windows the pop-out can drop a chat into
    r = ctx.run(["tmux", "list-windows", "-a", "-F",
                 "#{session_name}:#{window_index}\t#{window_name}\t#{window_panes}"])
    targets = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            targets.append({"target": parts[0], "name": parts[1],
                            "panes": int(parts[2]) if parts[2].isdigit() else 1})
    req._send(200, json.dumps(targets))


def popout(req, raw):   # POST /chat-popout — resume a chat's headless session in an interactive tmux claude
    d = json.loads(raw or "{}")
    session = (d.get("session") or "").strip()
    branch = (d.get("branch") or "").strip()
    target = (d.get("target") or "").strip()
    if not session or not branch:
        req._send(400, json.dumps({"ok": False, "err": "need a session + branch"}))
        return
    # Resume MUST run where the chat ran — claude sessions are scoped to their project dir,
    # so we hand the script the exact cwd chat.start used (the worktree, else the server's repo).
    cwd = _worktree_for(branch) or ctx.CWD
    args = [os.path.join(ctx.SCRIPTS, "stack-claude-resume"), session, cwd, branch]
    if target:
        args.append(target)
    r = ctx.run(args)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout.strip(), "err": r.stderr.strip()}))

READ_ONLY_TOOLS = ["Read", "Grep", "Glob"]
# Model aliases the chat may use — resolved to current models by the claude CLI, so no dated
# IDs to rot. Anything else from the client falls back to the default (never passed raw to --model).
ALLOWED_MODELS = {"opus", "sonnet", "haiku"}
DEFAULT_MODEL = "sonnet"


def _worktree_for(branch):
    # The worktree that currently holds this branch, so Read/Grep see the branch's tree
    # (not the main checkout, which may be on something else). None → fall back to CWD.
    out = ctx.run(["git", "worktree", "list", "--porcelain"]).stdout
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[9:]
        elif line.startswith("branch ") and line[7:].strip() == f"refs/heads/{branch}":
            return cur
    return None


# The branch's combined review diff (parent…branch), computed server-side so the page doesn't
# have to ship the whole thing. Capped — headless claude can Read individual files for the rest.
def _branch_diff(branch):
    parent = ctx.run(["git", "config", f"stack-branch.{branch}.parent"]).stdout.strip() or "main"
    out = ctx.run(["git", "diff", f"{parent}...{branch}"]).stdout
    cap = 80_000
    if len(out) > cap:
        out = out[:cap] + f"\n\n… (diff truncated at {cap} chars — use Read on individual files for the rest)"
    return out


# ── background chat jobs ──────────────────────────────────────────────────
# A chat turn runs as a server-side JOB whose claude subprocess is decoupled from the HTTP
# request: it buffers its whole event stream and runs to completion no matter who's connected,
# so closing the tab (or reloading) never kills or loses an in-flight answer. A request — the
# first one OR a reconnect — SUBSCRIBES: replay the buffer so far, then live-tail to the end.
# Keyed by a client-supplied turn id (crypto.randomUUID), so a reload can re-attach to its turn.
_JOBS = {}
_JOBS_LOCK = threading.Lock()
JOB_TTL = 1800        # keep a finished job's buffer this long for a late reconnect (seconds)
MAX_JOBS = 60         # bound memory; oldest FINISHED jobs evicted first (running ones never)


class Job:
    def __init__(self):
        self.events = []          # [(event, obj)] — the full SSE log, replayable from 0
        self.done = False
        self.session_id = ""
        self.proc = None
        self.created = time.time()
        self.cond = threading.Condition()

    def emit(self, event, obj):
        with self.cond:
            self.events.append((event, obj))
            if event == "session":
                self.session_id = obj.get("session_id", self.session_id)
            if event in ("done", "error"):
                self.done = True
            self.cond.notify_all()


def _prune():
    # caller holds _JOBS_LOCK. Drop finished jobs past their TTL, then, if still over budget,
    # evict the oldest finished ones. A running job is never evicted.
    now = time.time()
    for tid in [t for t, j in _JOBS.items() if j.done and now - j.created > JOB_TTL]:
        del _JOBS[tid]
    if len(_JOBS) > MAX_JOBS:
        finished = sorted((j.created, t) for t, j in _JOBS.items() if j.done)
        for _, tid in finished[: len(_JOBS) - MAX_JOBS]:
            del _JOBS[tid]


def _run_claude(job, cmd, cwd):
    # The job's lifetime — runs to completion regardless of any client. Parses claude's
    # stream-json into the same SSE events the client already understands.
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
        job.proc = proc
        text_seen = False
        job.emit("status", {"s": "starting"})
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = ev.get("type")
            if t == "system" and ev.get("subtype") == "init":
                sid = ev.get("session_id", "")
                if sid:
                    job.emit("session", {"session_id": sid})
            elif t == "stream_event":
                e = ev.get("event", {})
                et = e.get("type")
                if et == "content_block_delta":
                    delta = e.get("delta", {})
                    dt = delta.get("type")
                    if dt == "text_delta":
                        job.emit("token", {"t": delta.get("text", "")})
                        text_seen = True
                    elif dt == "thinking_delta":
                        job.emit("status", {"s": "thinking"})
                elif et == "content_block_start":
                    if e.get("content_block", {}).get("type") == "text":
                        # claude interleaves text→tool→text as separate blocks; their deltas
                        # carry no space across the join, so a later block glues onto the prior
                        # sentence ("…precisely.Now…"). Re-paragraph at each new text block.
                        if text_seen:
                            job.emit("token", {"t": "\n\n"})
                        job.emit("status", {"s": "writing"})
            elif t == "result":
                job.emit("done", {"ok": not ev.get("is_error"), "session_id": job.session_id})
        proc.wait()
        if proc.returncode not in (0, None) and not job.done:
            err = (proc.stderr.read() or "").strip()[:400] if proc.stderr else ""
            job.emit("error", {"err": err or f"claude exited {proc.returncode}"})
    except Exception as e:   # a job thread must never die silently — surface it to subscribers
        if not job.done:
            job.emit("error", {"err": str(e)[:400]})
    finally:
        # natural end OR explicit /chat-stop (proc SIGKILLed) → guarantee one terminal frame so
        # every subscriber unblocks and the turn reads as finished.
        if not job.done:
            job.emit("done", {"ok": True, "session_id": job.session_id})


def _subscribe(req, job, from_idx=0):
    req.send_response(200)
    req.send_header("Content-Type", "text/event-stream")
    req.send_header("Cache-Control", "no-store")
    req.send_header("Connection", "keep-alive")
    req.end_headers()
    i = from_idx
    try:
        while True:
            with job.cond:
                while i >= len(job.events) and not job.done:
                    job.cond.wait(timeout=15)
                batch = job.events[i:]
                i = len(job.events)
                done = job.done
            for event, obj in batch:
                req.wfile.write(f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode())
            if not batch:
                req.wfile.write(b": ping\n\n")   # keepalive while idle (long thinking, no tokens yet)
            req.wfile.flush()
            if done and i >= len(job.events):
                break
    except (OSError, BrokenPipeError):
        pass   # THIS subscriber dropped (tab closed) — the job keeps running for a reconnect


def stop(req, raw):   # POST /chat-stop {turn} — the ■ button: kill this turn's claude for real
    d = json.loads(raw or "{}")
    turn = (d.get("turn") or "").strip()
    job = _JOBS.get(turn)
    if job and job.proc and job.proc.poll() is None:
        try:
            os.killpg(os.getpgid(job.proc.pid), signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
    req._send(200, json.dumps({"ok": True}))


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    path = (d.get("path") or "").strip()
    question = (d.get("question") or "").strip()
    resume = (d.get("resume") or "").strip()
    turn = (d.get("turn") or "").strip()
    model = (d.get("model") or "").strip()
    if model not in ALLOWED_MODELS:
        model = DEFAULT_MODEL
    if not branch or not turn:
        req._send(400, json.dumps({"ok": False, "err": "need a branch + turn"}))
        return

    job = _JOBS.get(turn)
    # A reconnect (no question) to a job that's gone — expired, or the server restarted. Tell the
    # client so it falls back to --resume from the session id it already persisted.
    if job is None and not question:
        req.send_response(200)
        req.send_header("Content-Type", "text/event-stream")
        req.send_header("Cache-Control", "no-store")
        req.end_headers()
        try:
            req.wfile.write(b"event: gone\ndata: {}\n\n")
            req.wfile.flush()
        except (OSError, BrokenPipeError):
            pass
        return

    if job is None:
        # Build the command OUTSIDE the lock (prompt building can do git I/O), then create under
        # the lock with a double-check so two concurrent reconnects don't double-spawn the turn.
        # A resumed turn already carries its context — just send the question. A fresh turn seeds
        # the diff + ground rules: one file when a path is given, else the whole branch.
        if resume:
            prompt = question
        elif path:
            prompt = prompts.file_chat(branch, path, d.get("patch", ""), question)
        else:
            prompt = prompts.branch_chat(branch, d.get("patch") or _branch_diff(branch), question)
        cwd = _worktree_for(branch) or ctx.CWD
        cmd = ["claude", "-p", prompt,
               "--output-format", "stream-json",
               "--include-partial-messages",
               "--verbose",
               "--model", model]
        if resume:
            cmd += ["--resume", resume]
        # variadic — keep it LAST so it doesn't swallow a following flag's value
        cmd += ["--allowedTools", *READ_ONLY_TOOLS]
        with _JOBS_LOCK:
            job = _JOBS.get(turn)
            if job is None:
                job = Job()
                _JOBS[turn] = job
                _prune()
                threading.Thread(target=_run_claude, args=(job, cmd, cwd), daemon=True).start()

    _subscribe(req, job, 0)
