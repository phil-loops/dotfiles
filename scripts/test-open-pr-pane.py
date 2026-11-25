#!/usr/bin/env python3
"""srv/reviews.py's open-url {open:"tmux"}: a PR whose local branch has a pane goes to the newest such pane in
that repo; no local branch, or no pane on it, answers pane:null so the extension opens canopy instead."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from srv import ctx, reviews  # noqa: E402

LOOPS, OTHER = "/repos/loops", "/repos/other"
COMMON = {LOOPS: "/repos/loops/.git", "/repos/loops-wt-1": "/repos/loops/.git", OTHER: "/repos/other/.git"}
PANES = [
    {"pane": "%1", "repo_path": LOOPS, "branch": "fix-x", "at": 100},
    {"pane": "%2", "repo_path": "/repos/loops-wt-1", "branch": "fix-x", "at": 200},
    {"pane": "%3", "repo_path": OTHER, "branch": "fix-x", "at": 300},
    {"pane": "%4", "repo_path": LOOPS, "branch": None, "at": None},
]


def fake_run(calls):
    def run(argv, timeout=None):
        calls.append(argv)
        if argv[:2] == ["git", "-C"]:
            common = COMMON.get(argv[2])
            return subprocess.CompletedProcess(argv, 0 if common else 1, common or "", "")
        if argv[-1] == "--json":
            return subprocess.CompletedProcess(argv, 0, json.dumps(PANES), "")
        return subprocess.CompletedProcess(argv, 0, "tmux switch-client -t %2" if "--dry-run" in argv else "", "")
    return run


def answer(branch, dry=False):
    calls, sent = [], []
    ctx.init(run=fake_run(calls), ROOT=HERE, SCRIPTS=HERE, CWD=LOOPS, MAIN_WT=LOOPS, repos={})
    reviews._local_branch_for_pr = lambda num: branch
    reviews._resolve_repo = lambda slug: ("loops", LOOPS)

    class Req:
        def _send(self, code, body):
            sent.append((code, json.loads(body)))

    reviews._open_pr_pane(Req(), {"repo": "Loops-so/loops", "number": "7", "dry": dry})
    return sent[0], [c for c in calls if c[0].endswith("pane-branch") and c[1] == "tmux"]


def test_no_local_branch_answers_no_pane():
    (code, body), moves = answer(None)
    assert (code, body["pane"], moves) == (200, None, []), body


def test_branch_without_a_pane_answers_no_pane():
    (code, body), moves = answer("nobody-on-this")
    assert (code, body["pane"], body["branch"], moves) == (200, None, "nobody-on-this", []), body


def test_goes_to_the_newest_pane_on_the_branch_in_this_repo():
    (code, body), moves = answer("fix-x")
    assert (code, body["ok"], body["pane"]) == (200, True, "%2"), body
    assert moves == [[os.path.join(HERE, "pane-branch"), "tmux", "--prefer", "%2"]], moves


def test_dry_reports_without_moving():
    (_, body), moves = answer("fix-x", dry=True)
    assert body["would"] == "tmux switch-client -t %2", body
    assert moves[0][-1] == "--dry-run", moves


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
