# srv/assist.py — "select diff lines → ask Claude". The viewer sends the selected
# file:line ranges on a branch + a one-line instruction; we turn that into a prompt and
# fire a fresh standalone `claude` in the branch's worktree (via stack-claude).
#   POST /claude {branch, selections:[{path, ranges:[[start,end],…]}], instruction}
#
# /claude-stream is the same edit handed to a HEADLESS claude instead, streamed into the
# chat drawer as a chat.Job — so the work, its result, and its done-state live in the page
# rather than an invisible tmux window. Reconnect/stop/popout ride the existing chat
# machinery for free (the job sits in chat._JOBS keyed by the client's turn id).
#   POST /claude-stream {turn, branch, selections, instruction, model?}  → text/event-stream
import os
import json
import threading
import uuid
import subprocess

from . import chat, ctx, prompts

# Same editing toolset as the ejected rebase: file edits + git plumbing, but no push/PR
# tool — landing stays Phil's, so even a runaway session can't publish.
EDIT_TOOLS = ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]

# Model aliases the chip may request (resolved to current models by the claude CLI). Unlike the
# SSE chat, every chip launch is a FRESH session, so the chosen model always takes effect. An
# unrecognized value is dropped → stack-claude falls back to claude's configured default.
ALLOWED_MODELS = {"opus", "sonnet", "haiku"}


def _fmt_ranges(ranges):
    out = []
    for r in ranges:
        try:
            a, b = int(r[0]), int(r[1])
        except (TypeError, ValueError, IndexError):
            continue
        out.append(f"L{a}" if a == b else f"L{a}-{b}")
    return ", ".join(out)


def _selection_lines(selections):
    out = []
    for s in selections:
        path = s.get("path", "")
        rng = _fmt_ranges(s.get("ranges", []))
        out.append(f"- `{path}`" + (f" ({rng})" if rng else ""))
    return out


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    selections = [s for s in d.get("selections", []) if s.get("path")]
    instruction = d.get("instruction") or ""
    model = (d.get("model") or "").strip()
    if not branch or not selections:
        req._send(400, json.dumps({"ok": False, "err": "need a branch + at least one selection"}))
        return
    prompt = prompts.select_assist(branch, _selection_lines(selections), instruction)
    # ctx.run can't set env; stack-claude reads the model from STACK_CLAUDE_MODEL, so shell out
    # directly with it added (only when recognized — else the var stays unset = claude default).
    env = dict(os.environ)
    if model in ALLOWED_MODELS:
        env["STACK_CLAUDE_MODEL"] = model
    # Mint the spawned session's id here and hand it to claude (--session-id) via stack-claude,
    # so the fire-and-forget conversation is addressable later (--resume) and linkable from the
    # usage log — the chip echoes it back as a "claude" event.
    session_id = str(uuid.uuid4())
    env["STACK_CLAUDE_SESSION_ID"] = session_id
    r = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-claude"), branch, prompt],
                       cwd=ctx.CWD, capture_output=True, text=True, env=env)
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "sessionId": session_id, "out": r.stdout, "err": r.stderr}))


def _edit_cwd(branch):
    # Build/refresh the branch's scratch worktree exactly like stack-claude does, then resolve
    # it the same way: a real worktree holding the branch wins, else stack-open's scratch dir.
    subprocess.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", branch],
                   cwd=ctx.CWD, capture_output=True, text=True)
    d = chat._worktree_for(branch)
    if not d:
        d = os.path.join(os.environ.get("STACK_OPEN_DIR", "/tmp/stack-study"), branch.replace("/", "_"))
    return d if os.path.isdir(d) else None


def stream(req, raw):
    # POST /claude-stream — an edit action from the chat drawer, run headless + streamed.
    # Mirrors chat.start's job contract: keyed by the client's turn id, so a reload re-attaches
    # (via /chat with {turn}), ■ stop is /chat-stop, and popout resumes the reported session id.
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    turn = (d.get("turn") or "").strip()
    selections = [s for s in d.get("selections", []) if s.get("path")]
    instruction = (d.get("instruction") or "").strip()
    model = (d.get("model") or "").strip()
    if model not in ALLOWED_MODELS:
        model = "sonnet"
    if not turn or not branch:
        req._send(400, json.dumps({"ok": False, "err": "need a branch + turn"}))
        return

    job = chat._JOBS.get(turn)
    if job is None and not (selections and instruction):
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
        cwd = _edit_cwd(branch)
        if not cwd:
            req._send(500, json.dumps({"ok": False, "err": f"no worktree for {branch}"}))
            return
        prompt = prompts.select_assist(branch, _selection_lines(selections), instruction)
        repo_dir = ctx.repo_cwd()
        meta = {
            "branch": branch, "path": "", "question": instruction[:120], "edit": True,
            "repo": next((n for n, p in ctx.REPOS.items() if p == repo_dir), ""),
            "project": ctx.run(["git", "config", "--get", f"stack-branch.{branch}.project"]).stdout.strip(),
        }
        cmd = ["claude", "-p", prompt,
               "--output-format", "stream-json",
               "--include-partial-messages",
               "--verbose",
               "--model", model,
               # variadic — keep it LAST so it doesn't swallow a following flag's value
               "--allowedTools", *EDIT_TOOLS]
        with chat._JOBS_LOCK:
            job = chat._JOBS.get(turn)
            if job is None:
                job = chat.Job(meta)
                chat._JOBS[turn] = job
                chat._prune()
                threading.Thread(target=chat._run_claude, args=(job, cmd, cwd), daemon=True).start()

    chat._subscribe(req, job, 0)
