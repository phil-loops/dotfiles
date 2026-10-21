# srv/tutor.py — the Tutor tab: a Socratic session in the browser instead of the terminal.
#
# A turn is a headless, read-only `claude -p` (the chat's job runner + SSE stream, reused),
# seeded with the `tutor` skill, the learner's track from memory, and a browser protocol: three
# fenced blocks the page renders as UI instead of prose.
#
#   POST /tutor        {turn, target? | answer + resume}  → text/event-stream (chat.py's events)
#   GET  /tutor-src    ?path=&ref=                          → {path, ref, text} for the code pane
#   GET  /tutor-track                                        → {retest[], entries, path}
#   POST /tutor-ledger {topic, source, unaided[], …}         → append the approved close to the track
#   GET  /tutor-terminal                                     → recent terminal /tutor sessions to pick up
#   GET  /tutor-import ?session=                             → one terminal session's tutoring turns
#
# A picked-up terminal session continues as a FORK (--fork-session) in its own worktree, so the tab
# keeps everything that session already read and the terminal session itself is never touched.
#
# The session never writes memory itself: the close arrives as a block, the learner edits and
# approves it in the page, and only /tutor-ledger touches the track file.
import glob
import json
import os
import re
import subprocess
import threading
import time
from urllib.parse import parse_qs

from . import ctx, chat

SKILL_PATH = os.path.expanduser("~/.claude/skills/tutor/SKILL.md")
TRACK_NAME = "phil-learning-track"
TRACK_QUEUE = "## Re-test queue"
MODEL = "opus"
TAB_OPENER = "Start the session: prep silently, then open with step 2."   # also how /tutor-terminal skips the tab's own sessions
SRC_MAX = 400_000

TOOLS = ["Read", "Grep", "Glob", "Bash"]
ALLOWED = ["Read", "Grep", "Glob",
           "Bash(git show:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git blame:*)",
           "Bash(gh pr view:*)", "Bash(gh pr diff:*)"]

PROTOCOL = """
## You are running in the viewer's Tutor tab, not a terminal

The learner reads your turns in a browser. Three fenced blocks render as UI instead of text;
everything else is markdown prose. Use them exactly as shown — valid JSON, one block per fence.

```tutor-pin
{"path": "scripts/srv/chat.py", "ref": "origin/main", "lines": [428, 470]}
```
Pins a file in the code pane beside the question and lights `lines`. `path` is repo-relative
(or absolute); `ref` is any git ref/sha the file exists at — omit it for the working tree.
This REPLACES re-pasting code: pin it every rung that needs code, and only quote a line or two
inline when the rung is about that exact line. The pinned file is shown raw — no annotations
are possible there, which is the point.

```tutor-options
["the lock stops the second job from running", "the lock stops a second job from starting", "neither"]
```
Renders as clickable chips; a click sends that text as the learner's answer. No letters needed.

```tutor-ledger
{"topic": "…", "source": "PR #1234 / branch / concept", "unaided": ["…"], "scaffolded": ["… (what my framing did)"],
 "handed": ["…"], "misconceptions": ["… → unlocked by …"], "calibration": ["…"], "retest": ["…"], "retested": ["…"]}
```
Emit this ONCE, when the learner reaches the summit or wants to stop — it is the step-5 close.
`retest` = new items for the re-test queue; `retested` = queue items this session re-tested cold
AND they passed (copy their text exactly). The learner edits and approves it before anything is
saved — do NOT write to memory yourself; you can't, and the ledger block is the only channel.

The learner's answer box has no autosuggest, so short-answer rungs are no longer spoiled here —
but they're still weaker than reasoning-shaped ones.
"""


def _memory_dir():
    # Claude Code keys project memory by the main checkout's path with "/" and "." → "-".
    repo = ctx.MAIN_WT or ctx.repo_cwd()
    return os.path.expanduser("~/.claude/projects/" + re.sub(r"[/.]", "-", repo) + "/memory")


def _track_path():
    d = _memory_dir()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return None
    for n in names:
        if not n.endswith(".md"):
            continue
        p = os.path.join(d, n)
        with open(p, encoding="utf-8") as fh:
            head = fh.read(400)
        if re.search(rf"^name:\s*{TRACK_NAME}\s*$", head, re.M):
            return p
    return None


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _skill_body():
    text = _read(SKILL_PATH)
    return re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)


def _system_prompt():
    track = _read(_track_path() or "")
    return (_skill_body() + "\n" + PROTOCOL
            + "\n## The learner's track (memory `" + TRACK_NAME + "`)\n\n"
            + (track or "(no track found — this is a first session)"))


_JOBS = {}
_JOBS_LOCK = threading.Lock()


def start(req, raw):
    d = json.loads(raw or "{}")
    turn = (d.get("turn") or "").strip()
    target = (d.get("target") or "").strip()
    answer = (d.get("answer") or "").strip()
    resume = (d.get("resume") or "").strip()
    cwd = (d.get("cwd") or "").strip() or ctx.repo_cwd()
    if not turn:
        return req._send(400, json.dumps({"ok": False, "err": "need a turn id"}))
    if cwd not in _worktrees():
        return req._send(400, json.dumps({"ok": False, "err": f"not a worktree of this repo: {cwd}"}))

    job = _JOBS.get(turn)
    if job is None and not (target or answer):
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
        if resume:
            prompt = answer
        else:
            prompt = f"/tutor {target}\n\n{TAB_OPENER}"
        cmd = ["claude", "-p", prompt,
               "--output-format", "stream-json", "--include-partial-messages", "--verbose",
               "--model", MODEL, "--permission-mode", "default",
               "--append-system-prompt", _system_prompt()]
        if resume:
            cmd += ["--resume", resume]
            if d.get("fork"):
                cmd += ["--fork-session"]
        cmd += ["--tools", *TOOLS, "--allowedTools", *ALLOWED]
        with _JOBS_LOCK:
            job = _JOBS.get(turn)
            if job is None:
                job = chat.Job({"target": target})
                _JOBS[turn] = job
                now = time.time()
                for t in [t for t, j in _JOBS.items() if j.done and now - j.created > chat.JOB_TTL]:
                    del _JOBS[t]
                threading.Thread(target=chat._run_claude, args=(job, cmd, cwd), daemon=True).start()

    chat._subscribe(req, job, 0)


def stop(req, raw):
    turn = (json.loads(raw or "{}").get("turn") or "").strip()
    job = _JOBS.get(turn)
    if job and job.proc and job.proc.poll() is None:
        try:
            os.killpg(os.getpgid(job.proc.pid), 9)
        except (ProcessLookupError, OSError):
            pass
    req._send(200, json.dumps({"ok": True}))


def _inside(path, roots):
    real = os.path.realpath(path)
    return any(real == r or real.startswith(r + os.sep) for r in roots)


def src(req, u):
    q = parse_qs(u.query)
    path = q.get("path", [""])[0].strip()
    ref = q.get("ref", [""])[0].strip()
    repo = ctx.repo_cwd()
    if not path:
        return req._send(200, json.dumps({"err": "no path"}))
    if ref:
        if ref.startswith("-") or os.path.isabs(path):
            return req._send(200, json.dumps({"err": f"bad ref/path: {ref}:{path}"}))
        r = ctx.run(["git", "show", f"{ref}:{path}"])
        if r.returncode != 0:
            return req._send(200, json.dumps({"err": (r.stderr or "").strip()[:300] or "not found"}))
        text = r.stdout
    else:
        full = path if os.path.isabs(path) else os.path.join(repo, path)
        roots = [os.path.realpath(repo), os.path.realpath(os.path.expanduser("~/.dotfiles"))]
        if not _inside(full, roots):
            return req._send(200, json.dumps({"err": "outside the repo and dotfiles"}))
        text = _read(full)
        if not text and not os.path.isfile(full):
            return req._send(200, json.dumps({"err": f"no such file: {path}"}))
    req._send(200, json.dumps({"path": path, "ref": ref or "working tree", "text": text[:SRC_MAX]}))


QUEUE_ITEM = re.compile(r"^- \[( |x)\] (.+)$")


def _queue(text):
    out, inside = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            inside = line.strip() == TRACK_QUEUE
            continue
        m = QUEUE_ITEM.match(line) if inside else None
        if m and m.group(1) == " ":
            out.append(m.group(2).strip())
    return out


def track(req, u):
    path = _track_path()
    if not path:
        return req._send(200, json.dumps({"err": f"no memory named {TRACK_NAME} in {_memory_dir()}"}))
    text = _read(path)
    topics = re.findall(r"^- (?:\*\*)?([A-Z][^—\n]{3,80}?) — via ", text, re.M)
    req._send(200, json.dumps({"path": path, "retest": _queue(text), "topics": topics}))


def _clean(items):
    return [" ".join(str(x).split()) for x in (items or []) if str(x).strip()]


def _entry(d):
    head = " ".join(str(d.get("topic") or "Untitled").split())
    src_ = " ".join(str(d.get("source") or "").split())
    lines = [f"- {head} — via {src_ or 'the Tutor tab'}, {time.strftime('%Y-%m-%d')} (Tutor tab)."]
    for key, label in (("unaided", "Unaided"), ("scaffolded", "Scaffolded"), ("handed", "Handed"),
                       ("misconceptions", "⚠️ Misconception"), ("calibration", "Calibration")):
        items = _clean(d.get(key))
        if items:
            lines.append(f"  - **{label}:** " + " · ".join(items))
    return "\n".join(lines)


def ledger(req, raw):
    d = json.loads(raw or "{}")
    path = _track_path()
    if not path:
        return req._send(400, json.dumps({"ok": False, "err": f"no memory named {TRACK_NAME}"}))
    text = _read(path)
    if TRACK_QUEUE not in text:
        text = text.rstrip("\n") + f"\n\n{TRACK_QUEUE}\n"
    before, after = text.split(TRACK_QUEUE, 1)
    before = before.rstrip("\n") + "\n" + _entry(d) + "\n\n"

    passed = set(_clean(d.get("retested")))
    queue_lines = []
    for line in after.splitlines():
        m = QUEUE_ITEM.match(line)
        if m and m.group(1) == " " and " ".join(m.group(2).split()) in passed:
            line = f"- [x] {m.group(2)} — passed cold {time.strftime('%Y-%m-%d')}"
        queue_lines.append(line)
    topic = " ".join(str(d.get("topic") or "").split())
    for item in _clean(d.get("retest")):
        queue_lines.append(f"- [ ] {item}" + (f" ({topic})" if topic else ""))
    out = before + TRACK_QUEUE + "\n".join(queue_lines).rstrip("\n") + "\n"

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(out)
    os.replace(tmp, path)
    req._send(200, json.dumps({"ok": True, "path": path}))


def _worktrees():
    r = ctx.run(["git", "worktree", "list", "--porcelain"])
    return {ctx.repo_cwd()} | {ln[9:] for ln in r.stdout.splitlines() if ln.startswith("worktree ")}


SESSION_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
TERMINAL_WINDOW = 3 * 86_400


def _text(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def _is_tutor_load(text):
    return text.startswith("Base directory for this skill: ") and text.split("\n", 1)[0].rstrip().endswith("/skills/tutor")


def _tutoring(path):
    """The tutoring turns of a transcript — everything after its LAST tutor-skill load."""
    cwd, target, rows, started = "", "", [], False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            cwd = e.get("cwd") or cwd
            kind = e.get("type")
            if kind not in ("user", "assistant") or e.get("isSidechain"):
                continue
            text = _text(e.get("message", {}).get("content")).strip()
            if not text:
                continue
            if _is_tutor_load(text):
                started, rows = True, []
                continue
            if text.startswith("<"):
                m = re.search(r"<command-name>/tutor</command-name>\s*<command-args>(.*?)</command-args>", text, re.S)
                if m:
                    target = " ".join(m.group(1).split())
                continue
            if not started:
                continue
            role = "tutor" if kind == "assistant" else "me"
            if rows and rows[-1]["role"] == role:
                rows[-1]["text"] += "\n\n" + text
            else:
                rows.append({"role": role, "text": text})
    return cwd, target, rows


def _transcript(session):
    if not SESSION_ID.fullmatch(session):
        return None
    hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{session}.jsonl"))
    return hits[0] if hits else None


def _grep(flag, needle, paths):
    if not paths:
        return set()
    r = subprocess.run(["grep", flag, "-F", "--", needle, *paths], capture_output=True, text=True)
    return set(r.stdout.splitlines())


def terminal(req, u):
    now = time.time()
    recent = []
    for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
        try:
            if now - os.path.getmtime(path) <= TERMINAL_WINDOW:
                recent.append(path)
        except OSError:
            continue
    tutored = _grep("-l", "/skills/tutor", recent)
    candidates = tutored - _grep("-l", TAB_OPENER, sorted(tutored))
    out = []
    for path in candidates:
        mtime = os.path.getmtime(path)
        cwd, target, rows = _tutoring(path)
        if not rows or cwd not in _worktrees():
            continue
        last = next((r["text"] for r in reversed(rows) if r["role"] == "tutor"), "")
        out.append({"session": os.path.basename(path)[:-6], "cwd": cwd, "target": target, "mtime": mtime,
                    "answers": sum(r["role"] == "me" for r in rows), "last": last[-280:]})
    out.sort(key=lambda r: -r["mtime"])
    req._send(200, json.dumps(out[:8]))


def import_(req, u):
    session = parse_qs(u.query).get("session", [""])[0].strip()
    path = _transcript(session)
    if not path:
        return req._send(404, json.dumps({"err": f"no transcript for {session}"}))
    cwd, target, rows = _tutoring(path)
    if not rows:
        return req._send(200, json.dumps({"err": "that session never loaded the tutor skill"}))
    req._send(200, json.dumps({"session": session, "cwd": cwd, "target": target, "msgs": rows}))
