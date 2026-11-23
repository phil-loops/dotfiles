"""srv/asks.py — ask Claude about a change: one chat per subject, opened from canopy's review page.

An ask names a subject (a PR by number, else the branch's work, else its name) and the exact code Phil is
looking at (the tip and base canopy read). Four parts, each blind to the others:

  prompts   brief_prompt / line_prompt / moved_prompt: facts in, words out — no git, no tmux
  ledger    which chat answers for a subject, and the (base, tip) it was last told: one file per subject
            (named by a hash of it) under the repo's git dir, replaced
            atomically under its own lock file, written AHEAD of a launch and removed if the launch
            fails; an unreadable entry refuses rather than reading as "no chat"
  chats     an entry's chat counts while its presence record is live (chats.live: pid + start time), or
            for LAUNCH_GRACE after its launch returned (claude writes that record a few seconds in); a launch
            that fails after its chat came up anyway adopts that chat, since its session id was ours from the start
  ask       POST /ask {branch, kind: brief|line, sha, base, path?, side?, line?, startLine?}

Every chat opens with the brief: its first message, sent into a composer that is empty because the chat
is new — so "a chat exists" always means "the brief was asked". Nothing else is ever sent: a moved branch
and a line question are typed into the live chat unsent (a line ask on a subject with no chat opens one
with the brief, waits until it is live, then types the stub). Every chat runs under ASK_SETTINGS, which
refuses pushes and GitHub writes outright.
"""
import fcntl
import hashlib
import json
import os
import re
import subprocess
import time
import uuid

from . import chats, ctx, reviewdesk, watch

LEDGER_DIR = "canopy-asks"
LAUNCH_TIMEOUT = 75   # with READY_WAIT, the slowest answer stays well inside canopy's 120 s request timeout
READY_WAIT = 25
ADOPT_WAIT = 5        # after a failed launch: how long its pre-allocated session gets to show it's alive anyway
LAUNCH_GRACE = LAUNCH_TIMEOUT + READY_WAIT + 30   # outlives the slowest launch: no second press can start a twin under it
DESCRIPTION_CAP = 2000
LINE_CONTEXT = 12
ASK_SETTINGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ask-settings.json")
KINDS = ("brief", "line")
SHA = re.compile(r"^[0-9a-f]{40}$")


class Refused(Exception):
    """An ask that can't go: the reason, worded for Phil."""


# ── prompts ──────────────────────────────────────────────────────────────

def _about(branch, pr, purpose):
    if pr:
        return f"PR #{pr['number']} \"{pr.get('title') or ''}\" by {pr.get('author') or 'someone'}"
    return f"branch `{branch}`" + (f" ({purpose})" if purpose else "")


def brief_prompt(branch, base, tip, pr=None, purpose=""):
    """A chat's first message: what the change is for, how it works, and what could go wrong."""
    out = [f"Review {_about(branch, pr, purpose)}, for Phil.",
           f"It's checked out here as `{branch}`; the change Phil is reading is `git diff {base}...{tip}`.", ""]
    body = ((pr or {}).get("body") or "").strip()
    if body:
        if len(body) > DESCRIPTION_CAP:
            body = body[:DESCRIPTION_CAP] + " …"
        out += ["The author's description:"] + [f"> {ln}" if ln else ">" for ln in body.splitlines()] + [""]
    out += ["Read the whole diff and whatever code around it you need, then answer in plain language:",
            "1. What it's for: the problem or principle, in a sentence or two.",
            "2. How it works at its core.",
            "3. Concerns, worst first: bugs, holes, prod impact (data, migrations, deploy order, rollback), "
            "and whether it's the right and minimal design. Cite file:line and say how sure you are of each.",
            "",
            "Read and run whatever helps you answer, but don't change the branch: no edits, no commits."]
    return "\n".join(out)


def line_prompt(path, side, line, code, tip, start=None):
    """A stub for one line, typed into the chat that already has the brief — Phil types the question."""
    where = f"`{path}:{start}-{line}`" if start else f"`{path}:{line}`"
    old = " (the old side)" if side == "LEFT" else ""
    return "\n".join([f"At {tip[:7]}, {where}{old}:", "```", code, "```"]) + "\n\n"


def moved_prompt(branch, told, shown):
    """What a chat is told when the change on screen isn't the one it last read: (base, tip) pairs."""
    (old_base, old_tip), (base, tip) = told, shown
    if old_tip == tip:
        return (f"Phil is now reading `{branch}` against a different base: `git diff {base}...{tip}` "
                f"(you read it against {old_base[:7]}). Say what changes in your read.")
    return (f"`{branch}` moved since you read it: {old_tip[:7]} → {tip[:7]}, now read against {base[:7]}. "
            f"Your worktree is refreshed; read `git diff {old_tip}..{tip}` and say what changes in your read.")


# ── ledger ───────────────────────────────────────────────────────────────

def subject(branch, pr, work=""):
    """What a chat answers for: a PR whichever local branch shows it; else the branch's work, which
    survives a rename; else the branch's name."""
    if pr and pr.get("number"):
        return f"pr:{int(pr['number'])}"
    return f"work:{work}" if work else f"branch:{branch}"


def subject_key(subj):
    """The subject's file name: injective (a hash of the whole identity), so `feature/a` and `feature_a` never share."""
    return hashlib.sha256(subj.encode()).hexdigest()[:32]


class Entry:
    """One subject's entry, held under its lock file; `data` is replaced atomically (or removed) on exit.
    An unreadable entry refuses: corruption must never read as "no chat" and launch a twin."""

    def __init__(self, key, root=None):
        self.dir = os.path.join(root or watch.common_dir(), LEDGER_DIR)
        os.makedirs(self.dir, exist_ok=True)
        self.path = os.path.join(self.dir, key + ".json")

    def __enter__(self):
        self._lock = open(self.path + ".lock", "a")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        try:
            with open(self.path) as f:
                self.data = json.load(f)
        except FileNotFoundError:
            self.data = None
        except ValueError:
            fcntl.flock(self._lock, fcntl.LOCK_UN)
            self._lock.close()
            raise Refused(f"the ask ledger entry {self.path} is unreadable · move it aside to start fresh")
        self._before = json.dumps(self.data, sort_keys=True)
        return self

    def __exit__(self, *exc):
        try:
            if json.dumps(self.data, sort_keys=True) == self._before:
                return
            if self.data is None:
                os.unlink(self.path)
                return
            tmp = f"{self.path}.{os.getpid()}.tmp"
            with open(tmp, "w") as f:
                json.dump(self.data, f, sort_keys=True)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        finally:
            fcntl.flock(self._lock, fcntl.LOCK_UN)
            self._lock.close()


def standing(entry, now, live=None):
    """How an entry's chat stands: ("live", its presence record), ("starting", None) within the launch
    grace before that record exists, or (None, None) when it's gone and the entry is stale."""
    live = live or chats.live
    if not entry or not entry.get("session"):
        return None, None
    record = live(entry["session"])
    if record:
        return "live", record
    if now - entry.get("at", 0) < LAUNCH_GRACE:
        return "starting", None
    return None, None


# ── delivery ─────────────────────────────────────────────────────────────

def _launch(branch, session, brief, surface):
    """A new chat in the branch's worktree under ASK_SETTINGS, the brief its first message."""
    env = dict(os.environ, STACK_CLAUDE_SESSION_ID=session, STACK_CLAUDE_SETTINGS=ASK_SETTINGS,
               STACK_CLAUDE_PLACE="join" if surface else "window")
    env.pop("STACK_CLAUDE_DRAFT", None)
    try:
        r = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-claude"), branch], input=brief, text=True, env=env,
                           capture_output=True, cwd=ctx.repo_cwd(), timeout=LAUNCH_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Refused(f"the Claude window didn't open within {LAUNCH_TIMEOUT} s")
    if r.returncode != 0:
        raise Refused((r.stderr or r.stdout or "the Claude window didn't open").strip().splitlines()[-1])


def _await_live(session, wait=READY_WAIT, sleep=time.sleep, clock=time.monotonic, live=None):
    """Its presence record once the chat is live, else None after `wait` seconds."""
    live = live or chats.live
    end = clock() + wait
    while True:
        record = live(session)
        if record or clock() >= end:
            return record
        sleep(0.25)


def _draft_into(pane, text):
    """Type `text` into a live chat's composer as one bracketed paste, unsent, through a buffer of its own."""
    if not pane:
        raise Refused("that chat has no tmux pane to type into")
    buf = f"canopy-ask-{uuid.uuid4().hex[:12]}"
    try:
        subprocess.run(["tmux", "load-buffer", "-b", buf, "-"], input=text, text=True, check=True, capture_output=True)
        subprocess.run(["tmux", "paste-buffer", "-p", "-d", "-b", buf, "-t", pane], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        subprocess.run(["tmux", "delete-buffer", "-b", buf], capture_output=True)
        raise Refused(f"couldn't type into the chat's pane {pane}: {(e.stderr or '').strip() or e}")


def _refresh_worktree(branch):
    r = subprocess.run([os.path.join(ctx.SCRIPTS, "stack-open"), "--prepare", branch], capture_output=True, text=True,
                       cwd=ctx.repo_cwd(), timeout=LAUNCH_TIMEOUT)
    if r.returncode != 0:
        raise Refused(f"couldn't refresh {branch}'s worktree for its chat")


def _bring_forward(session):
    """Its pane to the front; why it couldn't be, else None — the ask itself already happened."""
    r = subprocess.run([os.path.join(ctx.SCRIPTS, "claude-jump"), session], capture_output=True, text=True, timeout=10)
    return None if r.returncode == 0 else ((r.stderr or r.stdout).strip() or "claude-jump failed")


# ── facts ────────────────────────────────────────────────────────────────

def _git(*args):
    return ctx.run(["git", *args])


def _shown(branch, sha, base):
    """The tip and base canopy showed, checked: both commits here, and the branch still at that tip."""
    if not (SHA.match(sha or "") and SHA.match(base or "")):
        raise Refused("this ask doesn't name the code shown · reload the diff")
    tip = _git("rev-parse", "--verify", "--quiet", f"refs/heads/{branch}^{{commit}}")
    if tip.returncode != 0:
        raise Refused(f"no branch {branch or '(none)'} here")
    if tip.stdout.strip() != sha:
        raise Refused(f"{branch} moved since this diff was read · reload it, then ask")
    if _git("cat-file", "-e", f"{base}^{{commit}}").returncode != 0:
        raise Refused(f"no base commit {base[:7]} here · reload the diff")
    return sha, base


def _code(tip, base, path, side, line, start):
    rev = tip if side != "LEFT" else (_git("merge-base", base, tip).stdout.strip() or base)
    shown = _git("show", f"{rev}:{path}")
    if shown.returncode != 0:
        raise Refused(f"no {path} at {rev[:7]}")
    lines = shown.stdout.splitlines()
    if line > len(lines):
        raise Refused(f"{path} has {len(lines)} lines at {rev[:7]}, not {line}")
    first = start or max(1, line - LINE_CONTEXT // 2)
    return "\n".join(lines[first - 1:line])


# ── the route ────────────────────────────────────────────────────────────

def ask(req, raw):
    try:
        d = json.loads(raw or "{}")
        if not isinstance(d, dict):
            raise ValueError
        return req._send(200, json.dumps(handle(d)))
    except Refused as e:
        return req._send(200, json.dumps({"ok": False, "err": str(e)}))
    except (ValueError, TypeError):
        return req._send(400, json.dumps({"ok": False, "err": "a malformed ask"}))


def handle(d, clock=time.time):
    branch, kind = d.get("branch") or "", d.get("kind") or "brief"
    if kind not in KINDS:
        raise Refused(f"no ask called {kind}")
    tip, base = _shown(branch, d.get("sha"), d.get("base"))
    stub = None
    if kind == "line":
        path, side = d.get("path") or "", "LEFT" if d.get("side") == "LEFT" else "RIGHT"
        line, start = int(d.get("line") or 0), int(d.get("startLine") or 0) or None
        if not (path and line > 0) or (start and not 0 < start <= line):
            raise Refused("a line ask needs a file and a line")
        stub = line_prompt(path, side, line, _code(tip, base, path, side, line, start), tip, start)
    pr = reviewdesk.reviewed().get(branch)
    work = _git("config", f"branch.{branch}.stack-work").stdout.strip()
    subj = subject(branch, pr, work)
    key, shown = subject_key(subj), [base, tip]
    now = clock()
    with Entry(key) as entry:
        if entry.data is not None and entry.data.get("subject") != subj:
            raise Refused(f"the ask ledger entry {entry.path} names another subject · move it aside")
        state, record = standing(entry.data, now)
        if state is None:
            session = str(uuid.uuid4())
            entry.data = {"subject": subj, "session": session, "at": now, "told": shown, "branch": branch}
        else:
            session, told = entry.data["session"], entry.data.get("told") or shown
    if state is None:
        # written ahead, then unlocked: a second press while it opens reads "starting", and a crash
        # mid-launch leaves an entry that lapses after LAUNCH_GRACE rather than an untracked twin chat
        purpose = _git("config", f"branch.{branch}.description").stdout.strip()
        try:
            _launch(branch, session, brief_prompt(branch, base, tip, pr, purpose), surface=stub is not None)
        except Refused:
            # the launcher can fail after its pane exists (a stall past the timeout): its session was ours
            # from the start, so a chat that comes live under it is adopted rather than orphaned as a twin
            if not _await_live(session, wait=ADOPT_WAIT):
                with Entry(key) as entry:
                    if (entry.data or {}).get("session") == session:
                        entry.data = None
                raise
        with Entry(key) as entry:   # the grace runs from the launch's end, however long it took
            if (entry.data or {}).get("session") == session:
                entry.data = {**entry.data, "at": clock()}
        if stub is None:
            return {"ok": True, "session": session, "reused": False, "kind": kind}
    elif state == "starting" and stub is None and told == shown:
        return {"ok": True, "session": session, "reused": True, "starting": True, "kind": kind}
    if state != "live":
        record = _await_live(session)
        if not record:
            raise Refused("the chat opened but isn't ready yet · ask again in a moment")
    # delivery under the subject's lock, from rereading what the chat was told through advancing it, so two
    # asks typing into one chat can't leave `told` disagreeing with the last paste
    with Entry(key) as entry:
        if (entry.data or {}).get("session") != session:
            raise Refused("this change's chat was replaced while asking · ask again")
        told = entry.data.get("told") or shown
        moved = told != shown
        drafts = []
        if moved:
            if told[1] != tip:
                _refresh_worktree(branch)
            drafts.append(moved_prompt(branch, told, shown))
        if stub:
            drafts.append(stub)
        if drafts:
            _draft_into(record.get("tmux_pane") or "", "\n\n".join(drafts))
        if moved:   # told only once it's typed in: a failed refresh or paste leaves the move still owed
            entry.data = {**entry.data, "told": shown, "branch": branch}
    out = {"ok": True, "session": session, "reused": state is not None, "kind": kind, "moved": moved}
    err = _bring_forward(session)
    return {**out, "forwardErr": err} if err else out
