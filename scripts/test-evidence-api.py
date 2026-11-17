#!/usr/bin/env python3
"""Endpoint evidence: request scenes, path predictions, the JSON path diff and its findings (no server)."""
import json
import os
import subprocess
import sys
import tempfile

tmp = tempfile.mkdtemp()
os.environ["EVIDENCE_CACHE"] = os.path.join(tmp, "cache")
os.environ["EVIDENCE_LEDGER"] = os.path.join(tmp, "ledger.jsonl")
here = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, here)
import evidence_core as E  # noqa: E402

failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def artifact(status, body):
    text = E._canon({"status": status, "contentType": "application/json", "body": body})
    sha = E._sha(text)
    os.makedirs(os.path.dirname(E._blob(sha)), exist_ok=True)
    open(E._blob(sha), "w").write(text)
    return sha


recipe = {"kind": "api", "requests": [{"id": "limits", "method": "GET", "path": "/api/x"}],
          "variants": [{"id": "dev"}]}
check([s["id"] for s in E.scenes_of(recipe)] == ["limits-dev"], "a request in a variant is one scene")
check([s["id"] for s in E.scenes_of({"kind": "api", "requests": recipe["requests"]})] == ["limits"],
      "a recipe without variants has one scene per request")
try:
    E.check_api_recipe({"kind": "api", "requests": [{"id": "w", "method": "POST", "path": "/api/x"}]})
    check(False, "a write request is refused")
except E.Refused:
    check(True, "a write request is refused (it would change the dev DB the next capture reads)")

check(E.predictions({"predict": {"*": {"paths": ["$.limit"]}}}, ["a"]) == {"a": {"paths": ["$.limit"]}},
      "a prediction can name the JSON paths that may change")
try:
    E.predictions({"predict": {"*": {"paths": []}}}, ["a"])
    check(False, "an empty paths prediction is refused")
except E.Refused:
    check(True, "an empty paths prediction is refused — say same")

d = E.json_diff({"a": 1, "b": {"c": 2}, "l": [1]}, {"a": 1, "b": {"c": 3, "d": 4}, "l": [1, 2]})
check({x["path"] for x in d} == {"$.b.c", "$.b.d", "$.l[1]"}, "the diff names every changed, added and removed path")
check(next(x for x in d if x["path"] == "$.b.d")["before"] is None and next(x for x in d if x["path"] == "$.b.d")["added"],
      "an added path says so")

same = artifact(200, {"limit": 10, "name": "t"})
more = artifact(200, {"limit": 20, "name": "t"})
renamed = artifact(200, {"limit": 20, "name": "u"})
broken = artifact(500, {"limit": 10, "name": "t"})
f = E.api_finding("s", {"paths": ["$.limit"]}, same, more)
check(not f["departure"] and f["diff"][0]["path"] == "$.body.limit", "a change inside the declared paths holds")
check(E.api_finding("s", {"paths": ["$.limit"]}, same, renamed)["departure"], "a change outside the declared paths departs")
check(E.api_finding("s", {"paths": ["$.limit"]}, same, broken)["departure"], "a status change departs from a paths prediction")
check(E.api_finding("s", "same", same, same)["departure"] is False and E.api_finding("s", "same", same, more)["departure"],
      "same holds only when nothing changed")
check(E.api_finding("s", "changes", same, more)["departure"] is False and E.api_finding("s", "changes", same, same)["departure"],
      "changes holds only when something did")
check(E.api_finding("s", {"paths": ["$.items[*].limit"]}, artifact(200, {"items": [{"limit": 1}]}),
                    artifact(200, {"items": [{"limit": 2}]}))["departure"] is False, "a path may use [*] for any index")

# ── the capture side's masking + canonical form (shared module, run in node) ──
js = f"""
import {{ mask, canon }} from {json.dumps(os.path.join(here, "evidence-json.mjs"))};
const body = {{ id: "x1", team: {{ id: "t", createdAt: "now", limit: 3 }}, rows: [{{ id: 1, v: 2 }}] }};
console.log(canon(mask(body, ["$..id", "$.team.createdAt"])));
"""
out = subprocess.run(["node", "--input-type=module", "-e", js], capture_output=True, text=True)
check(out.stdout.strip() == '{"rows":[{"v":2}],"team":{"limit":3}}',
      f"masks drop a key anywhere ($..) or at one path, and canon sorts keys ({out.stdout.strip() or out.stderr.strip()[-200:]})")

cov_recipe = {"kind": "api", "requests": [{"id": "r", "method": "GET", "path": "/api/trpc/admin.teamLimits", "file": "trpc/routers/admin.ts",
                                           "anchor": "teamLimits"}]}
repo = os.path.join(tmp, "repo")
os.makedirs(os.path.join(repo, "trpc", "routers"))
subprocess.run(["git", "init", "-q", repo], check=True)
for k, v in (("user.email", "t@t"), ("user.name", "t")):
    subprocess.run(["git", "-C", repo, "config", k, v], check=True)
open(os.path.join(repo, "trpc", "routers", "admin.ts"), "w").write("export const r = { teamLimits: 1 }")
subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
subprocess.run(["git", "-C", repo, "commit", "-qm", "b"], check=True)
b = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
open(os.path.join(repo, "trpc", "routers", "admin.ts"), "w").write("export const r = { teamLimits: 2 }")
subprocess.run(["git", "-C", repo, "commit", "-qam", "a"], check=True)
a = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
c = E.coverage(repo, {"beforeCommit": b, "afterCommit": a}, cov_recipe)
check(c["covered"] == ["trpc/routers/admin.ts"], "a request covers the router file its anchor lives in")

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
