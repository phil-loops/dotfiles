"""Import first in a test script: every git the test runs ignores the machine's global and system
config and reads only a test identity, with commit and tag signing off, from the environment
(2026-11-18: 40 scripts signed their fixture commits with Phil's key and broke whenever gpg-agent
was locked). Nothing is written, so nothing needs cleaning up."""
import os

_CONFIG = {"user.name": "test", "user.email": "test@example.invalid", "commit.gpgsign": "false",
           "tag.gpgsign": "false", "init.defaultBranch": "main"}
os.environ.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": str(len(_CONFIG))})
for _i, (_k, _v) in enumerate(_CONFIG.items()):
    os.environ[f"GIT_CONFIG_KEY_{_i}"], os.environ[f"GIT_CONFIG_VALUE_{_i}"] = _k, _v
for _k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    os.environ.pop(_k, None)
# a hook the test installs can't write the machine's pane record (scripts/pane-branch)
os.environ["PANE_BRANCH_DIR"] = os.path.join(os.devnull, "pane-branch")
