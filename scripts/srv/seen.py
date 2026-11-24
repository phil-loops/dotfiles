# srv/seen.py — a press acts on the commit Phil saw, never on whatever the branch holds when it lands.
# The door's writes (push, waive) name the tip that was on screen; a branch that moved since is
# refused with what's new, so the next press is made having seen it — never a trip to a chat.
from . import ctx


def tip(branch):
    return ctx.run(["git", "rev-parse", "--verify", "-q", f"refs/heads/{branch}"]).stdout.strip()


def moved(branch, saw):
    """None when <branch> is still at <saw>; else the refusal: what's there now and the commits
    that arrived since (oldest first), or rewritten when <saw> isn't under the new tip."""
    if not saw:
        return {"ok": False, "err": "this press didn't say which commit was on screen (expectTip) — an older canopy build; restart Show"}
    now = tip(branch)
    if not now:
        return {"ok": False, "err": f"no branch {branch}"}
    if now.startswith(saw) or saw == now:
        return None
    full = ctx.run(["git", "rev-parse", "--verify", "-q", f"{saw}^{{commit}}"]).stdout.strip()
    rewritten = not full or ctx.run(["git", "merge-base", "--is-ancestor", full, now]).returncode != 0
    rows = [] if rewritten else [ln.split("\t", 1) for ln in
                                 ctx.run(["git", "log", "--reverse", "--format=%h\t%s", f"{full}..{now}"]).stdout.splitlines() if "\t" in ln]
    commits = [{"short": s, "subject": subj} for s, subj in rows]
    if rewritten:
        said = f"{branch} was rewritten since you looked — now at {now[:7]}"
    else:
        first = commits[0] if commits else {"short": now[:7], "subject": ""}
        more = f" +{len(commits) - 1} more" if len(commits) > 1 else ""
        said = f"{branch} moved since you looked: {first['short']} {first['subject']}{more}"
    return {"ok": False, "moved": True, "now": now, "rewritten": rewritten, "commits": commits, "err": said}
