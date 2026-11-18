#!/usr/bin/env python3
"""stack-gates' pick_gates: gates follow what the diff touches. Temp repos with origin/main
written by update-ref — no remote, no push, no gate actually run."""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("stack_gates", os.path.join(HERE, "stack-gates"))
spec = importlib.util.spec_from_loader("stack_gates", loader)
sg = importlib.util.module_from_spec(spec)
loader.exec_module(sg)
env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
for k in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
    env.pop(k, None)
failures = 0
GATES = [("fresh", "true"), ("typecheck", "tsc"), ("format", "oxfmt"), ("lint", "task lint"), ("tests", "delta")]


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def repo(files):
    r = os.path.join(tempfile.mkdtemp(prefix="gate-select-"), "r")
    subprocess.run(["git", "init", "-q", "-b", "main", r], check=True, env=env)
    g = lambda *a: subprocess.run(["git", "-C", r, *a], capture_output=True, text=True, env=env, check=True)  # noqa: E731
    os.makedirs(os.path.join(r, "packages/prisma/migrations/1_x"), exist_ok=True)
    os.makedirs(os.path.join(r, "lib"), exist_ok=True)
    base = {"packages/prisma/schema.prisma": "model Team {\n  id String @id\n  teamId String\n}\n",
            "lib/team.ts": "export const read = (t: { teamId: string }) => t.teamId;\n", "README.md": "x\n"}
    for p, t in base.items():
        open(os.path.join(r, p), "w").write(t)
    g("add", "-A"); g("commit", "-q", "-m", "root")
    g("update-ref", "refs/remotes/origin/main", "HEAD")
    g("checkout", "-q", "-b", "b")
    for p, t in files.items():
        os.makedirs(os.path.dirname(os.path.join(r, p)), exist_ok=True)
        open(os.path.join(r, p), "w").write(t)
    g("add", "-A"); g("commit", "-q", "-m", "change")
    return r


def pick(files):
    r = repo(files)
    return sg.pick_gates(r, "b", list(GATES))


mig = {"packages/prisma/migrations/2_reason/migration.sql": "ALTER TABLE x ADD COLUMN y text;\n"}
gates, skips, note = pick({**mig, "packages/prisma/schema.prisma": "model Team {\n  id String @id\n  teamId String\n  disableReason String?\n}\n"})
check("migration-only with a field nothing reads: lint, tests, format and typecheck skip",
      set(skips) == {"typecheck", "lint", "tests", "format"}, skips)
check("…and squawk runs on the new migration", any(n == "squawk" and "2_reason/migration.sql" in c for n, c in gates), gates)

gates, skips, note = pick({**mig, "packages/prisma/schema.prisma": "model Team {\n  id String @id\n  teamId Int\n}\n"})
check("a schema change to a field code reads keeps typecheck", "typecheck" not in skips and "teamId" in note, (skips, note))

gates, skips, _ = pick({"lib/team.ts": "export const read = (t: { teamId: string }) => t.teamId.trim();\n"})
check("a code change keeps the full set", skips == {} and not any(n == "squawk" for n, _ in gates))

gates, skips, _ = pick({"lib/team.test.ts": "test('x', () => {});\n"})
check("a test-only change runs its tests and format, skips typecheck and lint",
      set(skips) == {"typecheck", "lint"}, skips)

gates, skips, _ = pick({"README.md": "y\n"})
check("a docs-only change skips all four", set(skips) == {"typecheck", "lint", "tests", "format"}, skips)

gates, skips, _ = pick({".oxlintrc.json": "{}\n"})
check("a file kind nobody mapped (config) keeps the full set", skips == {}, skips)

gates, skips, _ = pick({**mig, "lib/team.ts": "export const read = (t: { teamId: string }) => t.teamId.trim();\n"})
check("a migration with code keeps the full set and adds squawk", skips == {} and any(n == "squawk" for n, _ in gates))

print("all passed" if not failures else f"{failures} failed")
sys.exit(1 if failures else 0)
