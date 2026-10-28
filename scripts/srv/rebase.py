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
#
#   rebase.start(branch, cwd, prompt)          → job key; launches once (idempotent per branch)

from srv import chat, runs

# git plumbing + conflict edits. No push/PR tool — landing stays Phil's, so even a runaway
# session can't publish. Bare "Bash" pre-approves git; headless claude never prompts, so a tool
# outside this list is denied rather than blocking.
REBASE_TOOLS = ["Bash", "Read", "Edit", "Write", "Grep", "Glob"]


def job_key(branch):
    # one rebase per branch — a double "prep to merge" re-attaches instead of spawning a second.
    return f"rebase:{branch}"


def start(branch, cwd, prompt, model="sonnet"):
    """Launch (once) a headless claude that rebases `branch` onto origin/main in `cwd`, as a
    chat turn (a run on disk) keyed by the branch so any subscriber can replay + tail it. A live job for this
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
        live = runs.find("turn", key)
        if live and live.alive():
            chat.attach(chat._JOBS, key, lambda m: chat.Job())
            return key
        chat._JOBS.pop(key, None)
        chat.launch(chat._JOBS, key, lambda m: chat.Job(), cmd, cwd, {})
    return key

