# srv/tutor.py — the Tutor tab: a Socratic session in the browser instead of the terminal.
#
# A turn is a headless, read-only `claude -p` (the chat's job runner + SSE stream, reused),
# seeded with the `tutor` skill, the learner's concept graph (scripts/learning.py), and a browser
# protocol of fenced blocks the page renders as UI instead of prose. When a turn ends, its map /
# evidence / calibration blocks are applied to the graph and a `graph` event goes out before `done`.
#
#   POST /tutor             {turn, tab, topic?, target? | answer + resume + primed?, cwd?, fork?} → SSE
#
# `claude -p --resume` silently drops --append-system-prompt (verified 2026-10-21), so a resumed
# session that hasn't seen the tab's instructions yet (a terminal pick-up) gets them inside its
# first message instead — once per version of the instructions: the client stores the version it
# was primed with (`primed`), and a changed skill or protocol re-primes on the next turn.
#   GET  /tutor-src         ?path=&ref=                          → a pinned file for the code pane
#   GET  /tutor-terminal                                         → recent terminal /tutor sessions
#   GET  /tutor-import      ?session=                            → one of them as tab turns
#   GET  /learning-state                                         → the graph with derived depth + due
#   POST /learning-evidence {op: edit|delete, id, fields?}       → the learner audits a credit
#   POST /learning-question {op: add|close|reopen, text?, concept?, topic?, id?}
#
# A picked-up terminal session continues as a FORK (--fork-session) in its own worktree, so the tab
# keeps everything that session already read and the terminal session itself is never touched.
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs

from . import ctx, chat

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import learning  # noqa: E402

SKILL_PATH = os.path.expanduser("~/.claude/skills/tutor/SKILL.md")
MODEL = "opus"
TAB_OPENER = "Start the session: prep silently, then open with step 2."   # also how /tutor-terminal skips the tab's own sessions
SRC_MAX = 400_000

TOOLS = ["Read", "Grep", "Glob", "Bash"]
ALLOWED = ["Read", "Grep", "Glob",
           "Bash(git show:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git blame:*)",
           "Bash(gh pr view:*)", "Bash(gh pr diff:*)"]

PROTOCOL = """
## You are running in the viewer's Tutor tab, not a terminal

The learner reads your turns in a browser beside a map of the topic and a code pane. These fenced
blocks render as UI instead of text; everything else is markdown prose. Valid JSON, one per fence.
They are applied to the learner's concept graph when your turn ends — you never write files.

```tutor-map
{"topic": {"id": "ses-metric-projection", "title": "Mail send → SES feedback → metric projection", "source": "PR #11092"},
 "stages": [{"name": "Readers and bookmarks", "concepts": [
   {"id": "counts-and-bookmark-atomic", "name": "Effects and bookmark move together",
    "statement": "Applying effects and moving the bookmark must commit in one transaction.",
    "kind": "principle", "builds_on": ["cursor-redelivery"], "analogs": ["atomic-check-and-spend"],
    "code": [{"path": "packages/x/projector.ts", "ref": "origin/main", "lines": [40, 72]}]}]}]}
```
The step-1 map, as data: emit it once you've prepped (before the open) and again whenever it
changes. REUSE existing topic and concept ids from the graph below whenever it is the same idea —
that is what links topics. Add `analogs` across topics deliberately: a solid analog means go
problem-first; none means a worked run first. `kind`: principle (derivable) or convention (tell it).
Stages are ordered; 3–6 stations, each a few concepts.
If this conversation has no tutor-map yet (a session picked up from the terminal), emit one at the
top of your next turn, built from where the climb already is.

```tutor-rung
{"concept": "commit-order-not-stamp-order", "level": "predict", "rung": "predict", "confidence": true}
```
With every situation you pose: the concept it tests, the level (predict / explain / transfer /
critique), the rung kind (`predict`: closed, one behavior · `invent`: open, "invent the rule" — budget
these for the two or three concepts most others build on), and `confidence: true` when the learner
should rate their prediction before your reveal (the page shows low / medium / high chips after they
answer; the rating arrives appended to their answer as `(confidence: high)`). For a transfer rung add
`"via": "<analog concept id>"`; for the re-test of a miss add `"contrast_of": "<evidence id>"`. The
map highlights the concept as "you are here".

```tutor-evidence
[{"concept": "cursor-redelivery", "level": "predict", "credit": "unaided", "outcome": "hit",
  "note": "said the next tick starts back at 4", "confidence": "high", "rung": "predict"}]
```
At the top of the turn after each learner answer: your read of that answer, one entry per concept
it showed. credit — unaided: before your framing narrowed it; scaffolded: your framing did part of
the work; handed: you told it. When unsure, bump down; the learner audits every entry. Levels —
predict: said what happens in a situation; explain: said why; transfer: handled it cold in a new
setting (`"via"`: the analog it went through — required for an unaided transfer hit); critique:
spotted it, or its absence, in real code. Optional fields: `confidence` (low / medium / high — copy
the learner's rating from their answer), `rung` (predict / invent), and on a miss `contrast`: the
same situation with one variable changed so the wrong model and the right one diverge — the re-test
of that miss is its contrast, never the original situation again. A miss's `note` is the
misconception in the learner's own words. Depth is derived from this evidence; "held" means shown
unaided on two separate days, so a once-shown concept comes due the next day on purpose. There is no
end-of-session ledger.

```tutor-restate
{"concept": "counts-and-bookmark-atomic", "text": "move the counts and the bookmark in one go or not at all"}
```
At a station's summit, after you have said the principle plainly: the learner's own sentence for it,
lightly edited. A later re-test shows their sentence before yours.

```tutor-question
{"text": "what if the clock skews between the two databases?", "concept": "safety-lag"}
```
A question the learner raised in prose (when they didn't use the page's question box): recorded open
on the graph, on that concept. Follow it — it is a thread they chose.

The digest below lists, for the active topic, **cold opener** candidates (due concepts that are
analogs or prerequisites of this topic — the session's first situation, posed bare), **prerequisite
gaps** (teach or re-test the prerequisite with a situation before the concept that needs it) and
**transfer situations** (pose the concept in the analog's setting — the only way a transfer row is
earned). The close (step 5) is the consolidation — say each principle plainly, take their sentence —
plus evidence for the last answer.

```tutor-pin
{"path": "scripts/srv/chat.py", "ref": "origin/main", "lines": [428, 470]}
```
Pins a file in the code pane and lights `lines` (repo-relative or absolute path; `ref` any git
ref the file exists at, omit for the working tree). This replaces pasting code. The file shows raw.

```tutor-options
["the next tick re-reads 4–8", "the next tick starts at 9", "the next tick stops"]
```
Clickable candidate predictions (stuck protocol, step b). A click fills the answer box; the
learner still says why.

```tutor-calibration
["Strong analog for cursors: the croon lease sweeper."]
```
Rarely: a note about how this learner learns, kept for every future session.

The learner can send "Question about <concept name> [<id>]: …" — their own question, recorded open
in the graph. Follow it; it is a thread they chose. "Re-test me cold on … [<id>]" means one bare
situation with no setup, then evidence at level transfer. The answer box has no autosuggest.
"""


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _skill_body():
    text = _read(SKILL_PATH)
    return re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)


def _protocol_version():
    return hashlib.sha256((_skill_body() + PROTOCOL).encode()).hexdigest()[:12]


def _system_prompt(topic):
    return _skill_body() + "\n" + PROTOCOL + "\n" + learning.digest(learning.load(), topic=topic or None)


class TutorJob(chat.Job):
    """A chat Job that applies the turn's graph blocks just before `done`, so a client that
    refetches the graph on `done` always sees this turn's evidence."""

    def __init__(self, meta, tab, topic):
        super().__init__(meta)
        self.text = []
        self.tab = tab
        self.topic = topic
        self.protocol = _protocol_version()

    def emit(self, event, obj):
        if event == "token":
            self.text.append(obj.get("t", ""))
        if event == "done" and not self.done and not self.stopped:   # a cut-off turn's blocks are half-written
            try:
                with learning.editing() as g:
                    topic, applied, errors = learning.apply_blocks(g, "".join(self.text), session=self.tab, topic=self.topic)
            except Exception as exc:   # the turn's text still stands; say why the graph didn't move
                topic, applied, errors = self.topic, [], [str(exc)[:300]]
            super().emit("graph", {"topic": topic, "applied": applied, "errors": errors, "protocol": self.protocol})
        super().emit(event, obj)


_JOBS = {}
_JOBS_LOCK = threading.Lock()


def start(req, raw):
    d = json.loads(raw or "{}")
    turn = (d.get("turn") or "").strip()
    target = (d.get("target") or "").strip()
    answer = (d.get("answer") or "").strip()
    resume = (d.get("resume") or "").strip()
    tab = (d.get("tab") or "").strip()
    topic = learning.slug(d.get("topic")) if d.get("topic") else ""
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
        if resume and d.get("primed") != _protocol_version():
            prompt = ("<tutor-tab-instructions>\n" + _system_prompt(topic) + "\n</tutor-tab-instructions>\n\n"
                      "These instructions now govern this conversation and replace any earlier tutor-tab-instructions "
                      "(from here on you are in the Tutor tab). "
                      "The learner's message:\n\n" + answer)
        elif resume:
            prompt = answer
        else:
            prompt = f"/tutor {target}\n\n{TAB_OPENER}"
        cmd = ["claude", "-p", prompt,
               "--output-format", "stream-json", "--include-partial-messages", "--verbose",
               "--model", MODEL, "--permission-mode", "default",
               "--append-system-prompt", _system_prompt(topic)]
        if resume:
            cmd += ["--resume", resume]
            if d.get("fork"):
                cmd += ["--fork-session"]
        cmd += ["--tools", *TOOLS, "--allowedTools", *ALLOWED]
        with _JOBS_LOCK:
            job = _JOBS.get(turn)
            if job is None:
                job = TutorJob({"target": target}, tab, topic)
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
        job.stopped = True
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



def learning_state(req, u):
    req._send(200, json.dumps(learning.state(learning.load())))


def learning_evidence(req, raw):
    d = json.loads(raw or "{}")
    try:
        with learning.editing() as g:
            if d.get("op") == "delete":
                learning.delete_evidence(g, d.get("id", ""))
            else:
                learning.edit_evidence(g, d.get("id", ""), d.get("fields") or {})
    except learning.Invalid as exc:
        return req._send(400, json.dumps({"ok": False, "err": str(exc)}))
    req._send(200, json.dumps({"ok": True}))


def learning_question(req, raw):
    d = json.loads(raw or "{}")
    try:
        with learning.editing() as g:
            if d.get("op") in ("close", "reopen"):
                learning.set_question(g, d.get("id", ""), "answered" if d["op"] == "close" else "open")
                qid = d.get("id", "")
            else:
                qid = learning.add_question(g, d.get("text", ""), concept=d.get("concept", ""), topic=d.get("topic", ""))
    except learning.Invalid as exc:
        return req._send(400, json.dumps({"ok": False, "err": str(exc)}))
    req._send(200, json.dumps({"ok": True, "id": qid}))
