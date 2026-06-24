# srv/chat.py — "chat about this file", streamed into the browser. Runs a headless,
# READ-ONLY `claude -p` in the branch's worktree and proxies its stream-json output to
# the page as Server-Sent Events, so answer tokens land live instead of all-at-once.
# Multi-turn is stateless here: the client keeps the session_id we report on `done` and
# sends it back as `resume` for the next turn (so follow-ups keep the thread + the file
# context without us re-sending the diff).
#
#   POST /chat {branch, path?, patch?, question, resume?}  → text/event-stream
#     (omit path → chat about the whole branch; the server computes its parent…branch diff)
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


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    path = (d.get("path") or "").strip()
    question = (d.get("question") or "").strip()
    resume = (d.get("resume") or "").strip()
    model = (d.get("model") or "").strip()
    if model not in ALLOWED_MODELS:
        model = DEFAULT_MODEL
    if not branch or not question:
        req._send(400, json.dumps({"ok": False, "err": "need a branch + question"}))
        return

    # A resumed turn already carries its context in the session — just send the question. A fresh
    # turn seeds the diff + ground rules: one file when a path is given, else the whole branch.
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

    req.send_response(200)
    req.send_header("Content-Type", "text/event-stream")
    req.send_header("Cache-Control", "no-store")
    req.send_header("Connection", "keep-alive")
    req.end_headers()

    def sse(event, obj):
        req.wfile.write(f"event: {event}\ndata: {json.dumps(obj)}\n\n".encode())
        req.wfile.flush()

    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    session_id = ""
    text_seen = False
    try:
        sse("status", {"s": "starting"})
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
                session_id = ev.get("session_id", session_id)
            elif t == "stream_event":
                e = ev.get("event", {})
                et = e.get("type")
                if et == "content_block_delta":
                    delta = e.get("delta", {})
                    dt = delta.get("type")
                    if dt == "text_delta":
                        sse("token", {"t": delta.get("text", "")})
                        text_seen = True
                    elif dt == "thinking_delta":
                        sse("status", {"s": "thinking"})
                elif et == "content_block_start":
                    if e.get("content_block", {}).get("type") == "text":
                        # claude interleaves text→tool→text as separate blocks; their deltas
                        # carry no space across the join, so a later block glues onto the
                        # prior sentence ("…precisely.Now…"). Re-paragraph at each new text block.
                        if text_seen:
                            sse("token", {"t": "\n\n"})
                        sse("status", {"s": "writing"})
            elif t == "result":
                session_id = ev.get("session_id", session_id)
                sse("done", {"ok": not ev.get("is_error"), "session_id": session_id})
        proc.wait()
        if proc.returncode not in (0, None):
            err = (proc.stderr.read() or "").strip()[:400] if proc.stderr else ""
            sse("error", {"err": err or f"claude exited {proc.returncode}"})
    except (OSError, BrokenPipeError):
        pass  # browser closed the stream — fall through to the kill below
    finally:
        if proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
