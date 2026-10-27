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
import json
import subprocess
import threading
import time

from . import ctx


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
    def __init__(self, meta=None):
        self.events = []          # [(event, obj)] — the full SSE log, replayable from 0
        self.done = False
        self.ok = None            # terminal verdict — None while still running
        self.status = "starting"
        self.chars = 0            # answer characters streamed so far — the progress signal
        self.meta = meta or {}    # branch/path/question/repo/project — where this chat lives
        self.session_id = ""
        self.proc = None
        self.created = time.time()
        self.cond = threading.Condition()

    def emit(self, event, obj):
        with self.cond:
            self.events.append((event, obj))
            if event == "session":
                self.session_id = obj.get("session_id", self.session_id)
            elif event == "token":
                self.chars += len(obj.get("t", ""))
            elif event == "status":
                self.status = obj.get("s", self.status)
            if event in ("done", "error"):
                self.done = True
                self.ok = bool(obj.get("ok")) if event == "done" else False
                self.status = "done" if event == "done" else "error"
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


# What a tool call is ABOUT, for the one-line activity trace: the input key that best names
# the target, per tool. Everything else falls back to the first short string value.
_TOOL_ARG_KEYS = {"Read": "file_path", "Edit": "file_path", "Write": "file_path",
                  "Bash": "command", "Grep": "pattern", "Glob": "pattern"}


def _tool_arg(name, inp):
    v = inp.get(_TOOL_ARG_KEYS.get(name, ""), "")
    if not isinstance(v, str) or not v:
        v = next((x for x in inp.values() if isinstance(x, str) and x), "")
    v = " ".join(v.split())
    return v[:120] + ("…" if len(v) > 120 else "")


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
            elif t == "assistant":
                # each completed assistant message carries its tool_use blocks with FULL input
                # (the partial stream only has empty inputs) — emit one activity line per call so
                # a watcher sees what the session is DOING, not just its prose between tools.
                for block in ev.get("message", {}).get("content", []):
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        name = block.get("name", "")
                        job.emit("tool", {"name": name, "arg": _tool_arg(name, block.get("input") or {})})
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
        # natural end OR a killed proc → guarantee one terminal frame so
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

