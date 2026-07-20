#!/usr/bin/env python3
"""stack_facts — the single source of truth about a branch's place in its forest.

Everything the forest knows about a branch is derived HERE, once: its job, its purpose, its stored
summary, the project's whole plan in merge order (steps that already landed, steps still in flight),
each step's PR, and the graph edges. `stack-commit-body`, `stack-forest-mermaid` and `stack-pr-body`
are now RENDERERS over this — three views of one truth, so they cannot disagree.

They used to each derive it, and they had already drifted: a PR body named a branch by its
description while the map right below it named the same branch by its commit subject.

A real file, not a `python3 -c '...'` string: that pattern broke twice on an apostrophe closing the
shell quote.

  stack_facts.py facts   <branch>   → JSON
  stack_facts.py plan    <branch>   → the plan block for a commit body
  stack_facts.py mermaid <branch> [--fence]
"""
import json
import os
import subprocess
import sys


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout.strip()


def git_lines(*args):
    return [x for x in git(*args).splitlines() if x]


def parent_of(branch):
    return (git("config", f"branch.{branch}.stack-parent")
            or git("config", f"stack-branch.{branch}.parent") or "main")


def requires_of(branch):
    return (git_lines("config", "--get-all", f"branch.{branch}.stack-requires")
            or git_lines("config", "--get-all", f"stack-branch.{branch}.requires"))


def role_of(branch):
    """A branch's forest role. `proof` = a never-merge branch riding alongside its forest
    to prove it works (e2e/smoke artifacts). Set with `stack-proof`."""
    return (git("config", f"branch.{branch}.stack-role")
            or git("config", f"stack-branch.{branch}.role"))


def plan_omitted(branch):
    """Opted out of every rendered story (plan, PR body, mermaid) — an integration or
    test/proof branch that never ships as a PR. Set with `stack-plan-omit`; role=proof
    implies it."""
    if role_of(branch) == "proof":
        return True
    return (git("config", f"branch.{branch}.stack-plan-omit")
            or git("config", f"stack-branch.{branch}.plan-omit")) == "true"


def job_of(branch):
    """What this branch DOES, in one voiced line. A hand-authored `stack-branch.<b>.story` wins —
    it's the durable per-step merge story, editable from any branch's plan and re-read on every
    branch (so a story survives after this branch merges). Then the branch description: it is the
    branch's stated purpose and is maintained deliberately, so it outranks the commit subject,
    which is only an auto-derived gloss of the newest commit. Subject last, then the name."""
    story = (git("config", f"branch.{branch}.stack-story")
             or git("config", f"stack-branch.{branch}.story"))
    if story:
        return story
    description = git("config", f"branch.{branch}.description")
    if description:
        return description
    subject = git("log", "-1", "--format=%s", f"{parent_of(branch)}..{branch}")
    if ": " in subject:
        subject = subject.split(": ", 1)[1]
    return subject or branch


def _prs():
    """Every PR keyed by head branch, in ONE call — not one call per branch, four times over."""
    r = subprocess.run(
        ["gh", "pr", "list", "--state", "all", "--limit", "200",
         "--json", "number,state,headRefName"],
        capture_output=True, text=True)
    try:
        rows = json.loads(r.stdout)
    except Exception:
        return {}
    out = {}
    for row in rows:
        head = row["headRefName"]
        if head not in out:      # newest first — the first hit is the current PR for that branch
            out[head] = {"pr": row["number"], "state": row["state"].lower()}
    return out


def _landed(project):
    """Steps that already merged. The forest CONTRACTS as bases land — the branch is dropped and its
    config with it — so the live config alone would make a plan forget its own history exactly when
    that history matters most. The merge ledger outlives the branches, so read the landed steps from
    there. (It is written by the viewer, keyed by project, explicitly to survive contraction.)"""
    gd = git("rev-parse", "--git-common-dir")
    if gd and not os.path.isabs(gd):
        gd = os.path.join(os.getcwd(), gd)
    try:
        with open(os.path.join(gd, "stack-project-merges.json")) as f:
            hist = json.load(f).get("merges", {}).get(project, [])
    except Exception:
        return []
    if isinstance(hist, dict):
        hist = [hist]
    steps = []
    for e in reversed(hist):          # the ledger is newest-first; a plan reads oldest-first
        title = e.get("title") or ""
        steps.append({
            "job": title.split(": ", 1)[1] if ": " in title else title,
            "pr": e.get("pr"),
            "state": "merged",
            "landed": True,
            "branch": e.get("branch"),
        })
    return steps


def _order(branch):
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([os.path.join(here, "stack-merge-rank"), branch],
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout).get("order", [])
    except Exception:
        return []


def facts(branch):
    project = (git("config", f"branch.{branch}.stack-project")
               or git("config", f"stack-branch.{branch}.project"))
    order = _order(branch) if project else []
    prs = _prs() if (project or order) else {}

    plan = _landed(project) if project else []
    landed_branches = {s["branch"] for s in plan}
    for b in order:
        if b in landed_branches:      # already told as a landed step; do not tell it twice
            continue
        if plan_omitted(b):
            continue
        p = prs.get(b, {})
        plan.append({
            "job": job_of(b),
            "story": (git("config", f"branch.{b}.stack-story")
                      or git("config", f"stack-branch.{b}.story")),
            "pr": p.get("pr"),
            "state": p.get("state"),
            "landed": False,
            "branch": b,
            "parent": parent_of(b),
            "requires": requires_of(b),
            "me": b == branch,
        })
    for i, step in enumerate(plan, 1):
        step["n"] = i

    mine = next((s["n"] for s in plan if s.get("me")), None)
    parent = parent_of(branch)

    # UNBLOCKS — everything that builds on this: children (parent == this) ∪ consumers (require this)
    edges = {}
    for key, val in (l.split(" ", 1) for l in git_lines("config", "--get-regexp",
                                                        r"^stack-branch\..*\.(parent|requires)$")):
        name, kind = key[len("stack-branch."):].rsplit(".", 1)
        edges.setdefault((name, kind), []).append(val)
    new_edges = {}
    for key, val in (l.split(" ", 1) for l in git_lines("config", "--get-regexp",
                                                        r"^branch\..*\.stack-(parent|requires)$")):
        name, kind = key[len("branch."):].rsplit(".", 1)
        new_edges.setdefault((name, kind[len("stack-"):]), []).append(val)
    edges.update(new_edges)
    downstream = []
    for (name, _kind), vals in edges.items():
        if (branch in vals and name != branch and name not in downstream
                and not plan_omitted(name)):
            downstream.append(name)

    here = os.path.dirname(os.path.abspath(__file__))
    summary_status = subprocess.run([os.path.join(here, "stack-summary"), branch, "--status"],
                                    capture_output=True, text=True).stdout.strip()

    return {
        "branch": branch,
        "project": project,
        "role": role_of(branch),
        "purpose": git("config", f"branch.{branch}.description"),
        "summary": (git("config", f"branch.{branch}.stack-summary")
                    or git("config", f"stack-branch.{branch}.summary")),
        "summaryStatus": summary_status,
        "job": job_of(branch),
        "parent": parent,
        "buildsOn": None if parent == "main" else {"branch": parent, "job": job_of(parent),
                                                   **prs.get(parent, {})},
        "requires": [{"branch": r, "job": job_of(r), **prs.get(r, {})} for r in requires_of(branch)],
        "unblocks": [{"branch": d, "job": job_of(d), **prs.get(d, {})} for d in downstream],
        "position": mine,
        "total": len(plan),
        "plan": plan,
    }


# The plan is a per-PROJECT template, edited once and carried forward to every future child — so a
# framing you write survives the regenerate that each new branch triggers. The volatile facts (the
# #PR a step lands under, which line is "[this branch]", the position) are NEVER stored; they are
# re-derived on every render. Only the durable wording lives in config:
#   stack-project.<project>.plan-template  the outer block. Tokens {project}, {steps}.
#   stack-project.<project>.plan-step      one step's line.  Tokens {n} {ref} {job} {pr} {me}.
# Both default to the historical hardcoded format, so an untemplated project is byte-for-byte
# unchanged. NOTE: the outer template's first line must start with "Part of " — that literal is the
# fence stack-commit-body uses to replace the block idempotently.
PLAN_TEMPLATE_DEFAULT = "Part of a stack, in merge order:\n{steps}"
PLAN_STEP_DEFAULT = "  {n}. {ref}"


def _proj_cfg(project, key, default):
    # NOT git() — that strips, and a template's leading indent + internal newlines are load-bearing.
    # git config appends one trailing newline of its own; drop only that.
    r = subprocess.run(["git", "config", f"stack-project.{project}.{key}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return default
    val = r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout
    return val if val else default


def _render_step(tmpl, s):
    # a PR number is enough: GitHub expands it to the title and its merged/open state. {ref} is the
    # default face of a step — the landed PR, else "[this branch]" for the current one, else its job.
    if s.get("me"):
        ref = "[this branch]"
    elif s.get("pr"):
        ref = "#%s" % s["pr"]
    else:
        ref = s["job"]
    return (tmpl
            .replace("{n}", str(s["n"]))
            .replace("{ref}", ref)
            .replace("{job}", s["job"])
            .replace("{pr}", "#%s" % s["pr"] if s.get("pr") else "")
            .replace("{me}", " ← this branch" if s.get("me") else ""))


def render_plan(f):
    if not f["project"] or not f["plan"]:
        return ""
    project = f["project"]
    step_tmpl = _proj_cfg(project, "plan-step", PLAN_STEP_DEFAULT)
    steps = "\n".join(_render_step(step_tmpl, s) for s in f["plan"])
    outer = _proj_cfg(project, "plan-template", PLAN_TEMPLATE_DEFAULT)
    return outer.replace("{project}", project).replace("{steps}", steps)


def render_mermaid(f, fence=False):
    if not f["project"] or not f["plan"]:
        return ""
    ids = {s["branch"]: "b%d" % s["n"] for s in f["plan"] if s.get("branch")}
    out = ["flowchart TD", "  main([main])"]
    for s in f["plan"]:
        label = "%d · %s" % (s["n"], s["job"][:58])
        if s.get("pr"):
            label = "#%s · %s" % (s["pr"], label)
        if s.get("state") == "merged":
            label += " ✓"
        if s.get("me"):
            label += " ◀ this one"
        out.append('  %s["%s"]' % (ids[s["branch"]], label.replace('"', "'")))
    for s in f["plan"]:
        node = ids[s["branch"]]
        if s["landed"]:
            out.append("  main --> %s" % node)
            continue
        parent = s.get("parent", "main")
        out.append("  %s --> %s" % (ids.get(parent, "main"), node))
        for r in s.get("requires", []):
            if r in ids:
                out.append("  %s -. requires .-> %s" % (ids[r], node))
    me = next((s["branch"] for s in f["plan"] if s.get("me")), None)
    if me:
        out.append("  style %s stroke-width:3px" % ids[me])
    body = "\n".join(out)
    return "```mermaid\n%s\n```" % body if fence else body


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "plan-defaults":  # no branch needed
        print(json.dumps({"template": PLAN_TEMPLATE_DEFAULT, "step": PLAN_STEP_DEFAULT}))
        return 0
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    mode, branch = sys.argv[1], sys.argv[2]
    f = facts(branch)
    if mode == "facts":
        print(json.dumps(f, indent=2))
    elif mode == "plan":
        print(render_plan(f))
    elif mode == "mermaid":
        print(render_mermaid(f, fence="--fence" in sys.argv))
    else:
        print("unknown mode: %s" % mode, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
