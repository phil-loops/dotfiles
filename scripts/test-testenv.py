#!/usr/bin/env python3
"""testenv: a test's git ignores the machine's config — signing on with a signer that always fails
can't break a fixture commit — and every test script that commits loads it (or isolates itself)."""
import glob
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


root = tempfile.mkdtemp(prefix="testenv-check-")
hostile = os.path.join(root, "gitconfig")
with open(hostile, "w") as f:
    f.write("[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = /bin/false\n[user]\n\tname = machine\n\temail = machine@x\n")
env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
env["GIT_CONFIG_GLOBAL"] = hostile
script = (f"import sys; sys.path.insert(0, {HERE!r}); import testenv, subprocess, os\n"
          f"r = os.path.join({root!r}, 'r'); subprocess.run(['git', 'init', '-q', r], check=True)\n"
          "c = subprocess.run(['git', '-C', r, 'commit', '-q', '--allow-empty', '-m', 'x'], capture_output=True, text=True)\n"
          "print(c.returncode, subprocess.run(['git', '-C', r, 'log', '-1', '--format=%G?|%ae'], capture_output=True, text=True).stdout.strip())")
out = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, env=env).stdout.split()
check("a machine config that signs with a failing signer can't break a fixture commit", out[:1] == ["0"], out)
check("…the commit is unsigned and made by the test identity", out[1:] == ["N|test@example.invalid"], out)

bare = subprocess.run(["git", "-C", root, "init", "-q", os.path.join(root, "bare")], env=env, capture_output=True)
c = subprocess.run(["git", "-C", os.path.join(root, "bare"), "commit", "-q", "--allow-empty", "-m", "x"], env=env, capture_output=True)
check("(control: without testenv that config does break the commit)", c.returncode != 0)

# every script that commits loads testenv, or isolates git itself; seed-gen-cache runs against the real repo
OWN = re.compile(r"GIT_CONFIG_GLOBAL|GIT_CONFIG_NOSYSTEM|gpgsign")
missing = []
for f in sorted(glob.glob(os.path.join(HERE, "test-*"))):
    name = os.path.basename(f)
    if name in ("test-seed-gen-cache", "test-testenv.py"):
        continue
    try:
        s = open(f).read()
    except (UnicodeDecodeError, IsADirectoryError):
        continue
    if re.search(r"git.*commit", s) and "testenv" not in s and not OWN.search(s):
        missing.append(name)
check("every test script that commits ignores the machine's git config", not missing, missing)

print(f"\n{'OK' if not failures else 'FAIL'} — {failures} failure(s)")
sys.exit(1 if failures else 0)
