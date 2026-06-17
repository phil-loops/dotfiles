# srv/assist.py — "select diff lines → ask Claude". The viewer sends the selected
# file:line ranges on a branch + a one-line instruction; we turn that into a prompt and
# fire a fresh standalone `claude` in the branch's worktree (via stack-claude).
#   POST /claude {branch, selections:[{path, ranges:[[start,end],…]}], instruction}
import os
import json

from . import ctx


def _fmt_ranges(ranges):
    out = []
    for r in ranges:
        try:
            a, b = int(r[0]), int(r[1])
        except (TypeError, ValueError, IndexError):
            continue
        out.append(f"L{a}" if a == b else f"L{a}-{b}")
    return ", ".join(out)


def _build_prompt(branch, selections, instruction):
    lines = [f"You're in a worktree of branch `{branch}`. I selected these spots in its diff:"]
    for s in selections:
        path = s.get("path", "")
        rng = _fmt_ranges(s.get("ranges", []))
        lines.append(f"- `{path}`" + (f" ({rng})" if rng else ""))
    lines.append("")
    lines.append(instruction.strip() or "Review these and tell me what you'd improve.")
    return "\n".join(lines)


def start(req, raw):
    d = json.loads(raw or "{}")
    branch = (d.get("branch") or "").strip()
    selections = [s for s in d.get("selections", []) if s.get("path")]
    instruction = d.get("instruction") or ""
    if not branch or not selections:
        req._send(400, json.dumps({"ok": False, "err": "need a branch + at least one selection"}))
        return
    prompt = _build_prompt(branch, selections, instruction)
    r = ctx.run([os.path.join(ctx.SCRIPTS, "stack-claude"), branch, prompt])
    req._send(200 if r.returncode == 0 else 500,
              json.dumps({"ok": r.returncode == 0, "out": r.stdout, "err": r.stderr}))
