#!/usr/bin/env python3
"""Which production entry points reach what a branch changes (prod-callers): a throwaway repo with a job
registry, and a small stand-in for the viewer's TypeScript service that answers symbols, references and
definitions from the committed text. One branch changes code a job already reaches, adds code nothing
reaches, and connects existing unreached code to the job under a setting."""
import testenv  # noqa: F401,E402 — git here ignores the machine's config (testenv.py)
import importlib.machinery
import importlib.util
import os
import re
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("prod_callers", os.path.join(HERE, "prod-callers"))
pc = importlib.util.module_from_spec(importlib.util.spec_from_loader("prod_callers", loader))
loader.exec_module(pc)

REPO = os.path.realpath(tempfile.mkdtemp(prefix="prod-callers-test-"))
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("✓ " if ok else "✗ ") + name + ("" if ok else f" — {detail}"))
    failures += 0 if ok else 1


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=True).stdout


def commit(files, message):
    for path, text in files.items():
        full = os.path.join(REPO, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(text)
    git("add", "-A")
    git("commit", "-qm", message)


def files_at(sha):
    return {p: git("show", f"{sha}:{p}").split("\n") for p in git("ls-tree", "-r", "--name-only", sha).split()}


def symbols(lines):
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("import "):
            for name in re.findall(r"\w+", line.split(" from ")[0])[1:]:
                out.append({"name": name, "kind": "variable", "line": i + 1, "endLine": i + 1, "depth": 0})
        m = re.match(r"export (?:default )?(?:async )?(function|const) (\w+)", line)
        if m:
            end = next(j for j in range(i, len(lines)) if lines[j] in ("}", "};"))
            out.append({"name": m.group(2), "kind": "function" if m.group(1) == "function" else "variable", "line": i + 1, "endLine": end + 1, "depth": 0})
            if m.group(1) == "const":
                for j in range(i + 1, end):
                    member = re.match(r"  (\w+)[:,]", lines[j])
                    if member:
                        out.append({"name": member.group(1), "kind": "property", "line": j + 1, "endLine": j + 1, "depth": 1})
            i = end
        i += 1
    return out


def post(route, body):
    """The stand-in service: every word match is a reference, and a name is defined where it is declared."""
    tree = files_at(body["sha"])
    if route == "/lsp/symbols":
        return {"ok": True, "symbols": symbols(tree.get(body["path"], []))}
    word = re.match(r"\w+", tree[body["path"]][body["line"] - 1][body["character"]:]).group(0)
    if route == "/lsp/definition":
        for path, lines in tree.items():
            for s in symbols(lines):
                if s["name"] == word and s["depth"] == 0 and not lines[s["line"] - 1].startswith("import "):
                    return {"ok": True, "locations": [{"path": path, "line": s["line"], "character": 0}]}
        return {"ok": True, "locations": []}
    found = []
    for path, lines in sorted(tree.items()):
        for n, line in enumerate(lines, 1):
            for m in re.finditer(rf"\b{word}\b", line):
                if (path, n) != (body["path"], body["line"]):
                    found.append({"path": path, "line": n, "character": m.start()})
    return {"ok": True, "locations": found}


git("init", "-q")
SCAN = '''import {{ evaluate }} from "../lib/eval";
import {{ settings }} from "../lib/settings";{imports}
export default async function scan(
  deps = {{
    evaluate,{deps}
  }},
) {{
  await deps.evaluate();{body}
}}
'''
commit({
    "lib/judge.ts": "export function build() {\n  return 1;\n}\n",
    "lib/eval.ts": 'import { build } from "./judge";\nexport function evaluate() {\n  return build();\n}\n',
    "lib/compare.ts": "export function compare() {\n  return 2;\n}\n",
    "lib/compare.test.ts": 'import { compare } from "./compare";\ncompare();\n',
    "lib/settings.ts": "export const settings = {\n  shadow: () => false,\n};\n",
    "jobs/scan.ts": SCAN.format(imports="", deps="", body=""),
    "jobs/index.ts": 'import scan from "./scan";\nexport const jobs = {\n  scan,\n};\n',
}, "base")
git("branch", "-M", "main")
git("checkout", "-qb", "feature")
commit({
    "lib/judge.ts": "export function build() {\n  return 3;\n}\n",
    "lib/lonely.ts": "export function lonely() {\n  return 4;\n}\n",
    "lib/settings.ts": "export const settings = {\n  shadow: () => false,\n  other: () => true,\n};\n",
    "jobs/scan.ts": SCAN.format(imports='\nimport { compare } from "../lib/compare";',
                                deps="\n    compare,\n    shadowEnabled: () => settings.shadow(),",
                                body="\n  if (await deps.shadowEnabled()) {\n    await deps.compare();\n  }"),
}, "tip")

result = pc.report(REPO, "feature", "main", 0, post)
by = {d["name"]: d for d in result["declarations"] + result["connects"]}
check("code a job already reached is an existing caller, with the way there",
      by["build"]["answer"] == "existing" and [s["name"] for s in by["build"]["reached"][0]["path"]] == ["build", "evaluate", "scan", "job scan"], by["build"])
check("new code nothing reaches has no production caller; a test doesn't count", by["lonely"]["answer"] == "none" and not by["lonely"]["unresolved"], by["lonely"])
check("the changed job handler is reached by its own registration", by["scan"]["reached"][0]["by"] == "job scan" and by["scan"]["answer"] == "existing", by["scan"])
check("unchanged code the branch imports into a job is newly connected, behind the setting its call sits under",
      by["compare"]["answer"] == "connected" and by["compare"]["reached"][0].get("behind") == "shadow" and by["compare"] in result["connects"], by["compare"])
check("a registry answers with the entry that changed, not the table everything reads",
      "other" in by and "settings" not in by and by["other"]["answer"] == "none", sorted(by))
check("the base is the merge base, and nothing is checked out", result["base"] == git("rev-parse", "main").strip() and git("status", "--porcelain") == "")

SOURCE = "export async function run(deps = { flag: () => settings.on(), go }) {\n  if (!(await deps.flag())) return;\n  await deps.go();\n  plain();\n}".split("\n")


class Fake:
    def text(self, path):
        return SOURCE

    def symbols(self, path):
        return [{"name": "run", "kind": "function", "line": 1, "endLine": 5, "depth": 0}]


caller = {"path": "x.ts", "name": "run", "line": 1}
check("an early return on a setting guards the calls below it", pc.guard(Fake(), caller, "go") == "on", pc.guard(Fake(), caller, "go"))
SOURCE = "export function run() {\n  if (other) {\n    a();\n  }\n  go();\n}".split("\n")
check("a call under no setting has no flag", pc.guard(Fake(), caller, "go") is None and pc.guard(Fake(), caller, "a") is None)
check("entry points are named for what registers them",
      [pc.entry(p, "w") for p in ("jobs/index.ts", "script-runner/index.ts", "croon/x.ts", "pages/api/v1/a.ts", "trpc/routers/admin/b.ts", "lib/c.ts")]
      == ["job w", "script w", "cron x", "route /api/v1/a", "trpc admin/b", None])

print("--- all passed" if not failures else f"--- {failures} failed")
raise SystemExit(1 if failures else 0)
