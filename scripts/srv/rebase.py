# srv/rebase.py — the ejected forward-rebase, STREAMED. When /sync can't rebase a branch in
# place (a real conflict, or an unsafe-to-rebase layout) it used to hand the work to an
# interactive `claude` in a tmux window — and the viewer just showed a frozen "rebasing onto
# origin/main via Claude" line that looked identical whether the session was grinding away or
# long dead. Here we run that same rebase as a HEADLESS claude job and stream its output to
# the browser over SSE, reusing chat.py's job model wholesale (buffered, replayable, survives a
# closed tab). So "is it still working?" is answered by watching it work.
#
# Unlike chat (read-only), this job edits files + runs git to resolve conflicts — but it never
# pushes and never opens a PR; publishing stays Phil's, exactly like the old interactive eject.
# The escape hatch to take over by hand is the existing /chat-popout (resume the session id in
# an interactive tmux claude) — the job is a plain chat.Job, so its session id works there.
#
#   rebase.start(branch, cwd, prompt)          → job key; launches once (idempotent per branch)
#   POST /rebase-stream {branch}               → text/event-stream: replay + live-tail the job
#   POST /rebase-stop   {branch}               → SIGKILL the branch's rebase job
import json
import os
import signal
import threading

from srv import chat

# git plumbing + conflict edits. No push/PR tool — landing stays Phil's, so even a runaway
# session can't publish. Bare "Bash" pre-approves git; headless claude never prompts, so a tool
# outside this list is denied rather than blocking.
REBASE_TOOLS = ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]


def job_key(branch):
    # one rebase per branch — a double "prep to merge" re-attaches instead of spawning a second.
    return f"rebase:{branch}"


def start(branch, cwd, prompt, model="sonnet"):
    """Launch (once) a headless claude that rebases `branch` onto origin/main in `cwd`, as a
    chat.Job keyed by the branch so any subscriber can replay + tail it. A live job for this
    branch is reused, not re-spawned. Returns the job key to stream from."""
    key = job_key(branch)
    cmd = ["claude", "-p", prompt,
           "--output-format", "stream-json",
           "--include-partial-messages",
           "--verbose",
           "--model", model,
           # variadic — keep it LAST so it doesn't swallow a following flag's value
           "--allowedTools", *REBASE_TOOLS]
    with chat._JOBS_LOCK:
        job = chat._JOBS.get(key)
        if job is not None and not job.done:
            return key
        job = chat.Job()
        chat._JOBS[key] = job
        chat._prune()
        threading.Thread(target=chat._run_claude, args=(job, cmd, cwd), daemon=True).start()
    return key


def _send_gone(req):
    req.send_response(200)
    req.send_header("Content-Type", "text/event-stream")
    req.send_header("Cache-Control", "no-store")
    req.end_headers()
    try:
        req.wfile.write(b"event: gone\ndata: {}\n\n")
        req.wfile.flush()
    except (OSError, BrokenPipeError):
        pass


def stream(req, raw):   # POST /rebase-stream {branch} → SSE replay + live-tail of the rebase job
    branch = (json.loads(raw or "{}").get("branch") or "").strip()
    job = chat._JOBS.get(job_key(branch)) if branch else None
    if job is None:
        _send_gone(req)   # no job (expired / server restarted / never ejected) — client stops tailing
        return
    chat._subscribe(req, job, 0)


def stop(req, raw):   # POST /rebase-stop {branch} — kill the branch's rebase job for real
    branch = (json.loads(raw or "{}").get("branch") or "").strip()
    job = chat._JOBS.get(job_key(branch)) if branch else None
    if job and job.proc and job.proc.poll() is None:
        try:
            os.killpg(os.getpgid(job.proc.pid), signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
    req._send(200, json.dumps({"ok": True}))
