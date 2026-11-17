#!/usr/bin/env python3
"""evidence_core's judgment rules, on a throwaway cache + ledger (no rendering, no repo)."""
import copy
import json
import os
import sys
import tempfile

tmp = tempfile.mkdtemp()
os.environ["EVIDENCE_CACHE"] = os.path.join(tmp, "cache")
os.environ["EVIDENCE_LEDGER"] = os.path.join(tmp, "ledger.jsonl")
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import evidence_core as E  # noqa: E402

failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def blob(n):
    sha = f"{n:064x}"
    os.makedirs(os.path.dirname(E._blob(sha)), exist_ok=True)
    open(E._blob(sha), "wb").close()
    return sha


def publish(m):
    text = E._canon(m)
    mid = E._sha(text)
    E._write_atomic(E._manifest_path(mid), text)
    return mid


base = {
    "schema": E.SCHEMA, "repo": "r",
    "basis": {"beforeCommit": "b1", "afterCommit": "a1", "beforeTree": "bt", "afterTree": "at"},
    "recipe": {"name": "x", "digest": "d", "title": "X"},
    "expectation": "dark changes", "predict": {"dark": "changes"},
    "obligations": [{"id": "dark", "theme": "dark"}],
    "claim": "live", "captured": {"expectation": "dark changes", "predict": {"dark": "changes"}, "gaps": []},
    "amends": None, "retrospective": False, "gaps": [],
    "before": {"renderId": "rb", "scenes": {"dark": blob(1)}, "fields": {"dark": [10, 10, 100, 30]},
               "frames": {"dark": {"crop": [0, 0, 400, 200], "field": [10, 10, 100, 30], "dialog": None}}},
    "after": {"renderId": "ra", "scenes": {"dark": blob(2)}, "fields": {"dark": [10, 10, 100, 30]},
              "frames": {"dark": {"crop": [0, 0, 400, 200], "field": [10, 10, 100, 30], "dialog": None}}},
    "findings": [],
}
m1 = publish(base)

try:
    E.judge(m1, "maybe", "", "browser")
    check(False, "an unknown verdict is refused")
except E.Refused:
    check(True, "an unknown verdict is refused")
try:
    E.judge("0" * 64, "accept", "", "browser")
    check(False, "a manifest that doesn't exist can't be judged")
except E.Refused:
    check(True, "a manifest that doesn't exist can't be judged")

E.judge(m1, "accept", "looks right", "browser")
check(E.status(base, m1) == {"judged": True, "verdict": "accept", "at": E.status(base, m1)["at"],
                             "note": "looks right", "carriedFrom": None, "stands": True, "why": []},
      "Phil's own verdict reads back as his, not carried")
entry = json.loads(open(os.environ["EVIDENCE_LEDGER"]).read().splitlines()[-1])
check(entry["contents"] == base, "the ledger keeps what was judged, not just its id")

restacked = copy.deepcopy(base)
restacked["basis"] = {"beforeCommit": "b2", "afterCommit": "a2", "beforeTree": "bt2", "afterTree": "at2"}
restacked["before"]["renderId"] = "rb2"
m2 = publish(restacked)
s = E.status(restacked, m2)
check(s["judged"] and s["carriedFrom"] == m1, "identical pixels on a new tree carry the verdict, marked as carried")

for what, mutate in [
    ("a changed after-image", lambda m: m["after"]["scenes"].update(dark=blob(3))),
    ("a changed expectation", lambda m: m.update(expectation="dark changes subtly")),
    ("a changed scene obligation (same pixels)", lambda m: m["obligations"][0].update(focus="input")),
    ("a changed prediction", lambda m: m.update(predict={"dark": "same"})),
]:
    other = copy.deepcopy(restacked)
    mutate(other)
    mo = publish(other)
    check(not E.status(other, mo)["judged"], f"{what} carries nothing")

os.remove(E._blob(base["after"]["scenes"]["dark"]))
try:
    E.judge(m2, "accept", "", "browser")
    check(False, "a manifest whose images are gone can't be judged")
except E.Refused:
    check(True, "a manifest whose images are gone can't be judged")
check(E.blob_path("../../etc/passwd") is None, "blob lookup takes only a bare digest")


# ── coverage is part of what was judged ──
g1 = dict(base, gaps=["svix"])
g2 = dict(base, gaps=["svix", "honeypot"])
check(E.observation(g1) != E.observation(g2), "a manifest that admits a different gap is a different observation")
check(E.observation(dict(base, gaps=[])) == E.observation(base), "no gaps reads the same as a manifest from before gaps existed")

# ── v4: claim class, framing, eligibility, amendments ──
blob(1), blob(2)   # an earlier check deleted one to prove missing images block judging
moved = copy.deepcopy(base)
moved["after"]["frames"]["dark"]["crop"] = [0, 24, 400, 200]   # same pixels, the dialog 24px lower
check(E.observation(moved) != E.observation(base), "a picture that moved on the page is a different observation, even with identical pixels")
mm = publish(moved)
check(E.status(moved, mm).get("carriedFrom") is None, "a verdict doesn't carry to the same pixels in a new place")
old_engine = dict(copy.deepcopy(base), schema=1)
check(E.eligibility(old_engine) and "older engine" in E.eligibility(old_engine)[0], "a schema-1 manifest isn't eligible")
try:
    E.judge(publish(old_engine), "accept", "", "browser")
    check(False, "an ineligible manifest can't be judged")
except E.Refused:
    check(True, "an ineligible manifest can't be judged")
det = dict(copy.deepcopy(base), claim="deterministic")
E._write_atomic(E._admission_path("rb"), E._canon({"status": "admitted"}))
E._write_atomic(E._admission_path("ra"), E._canon({"status": "conflicted"}))
check(any("conflicted" in w for w in E.eligibility(det)), "a deterministic manifest whose render was revoked isn't eligible")
E._write_atomic(E._admission_path("ra"), E._canon({"status": "admitted"}))
check(E.eligibility(det) == [], "a deterministic manifest with both renders admitted is eligible")
dm = publish(det)
E.judge(dm, "accept", "", "browser")
det_twin = dict(copy.deepcopy(det), basis=dict(det["basis"], afterCommit="a2"))
tm = publish(det_twin)
check(E.status(det_twin, tm).get("carriedFrom") == dm, "an eligible identical observation carries the verdict")
E._write_atomic(E._admission_path("ra"), E._canon({"status": "conflicted"}))
s = E.status(det, dm)
check(s["judged"] and s.get("stands") is False and any("conflicted" in w for w in s.get("why", [])),
      "a verdict on a render revoked after judging no longer stands, and says why")
check(not E.status(det_twin, tm)["judged"], "a verdict doesn't carry onto a manifest that isn't eligible")
E._write_atomic(E._admission_path("ra"), E._canon({"status": "admitted"}))
check(E.status(det, dm).get("stands") is True, "a verdict on an eligible manifest stands")
src = dict(copy.deepcopy(det), basis=dict(det["basis"], afterCommit="a3"))
src["before"]["renderId"], src["after"]["renderId"] = "sb", "sa"
dst = dict(copy.deepcopy(src), basis=dict(det["basis"], afterCommit="a4"))
dst["before"]["renderId"], dst["after"]["renderId"] = "db", "da"
for r in ("sb", "sa", "db", "da"):
    E._write_atomic(E._admission_path(r), E._canon({"status": "admitted"}))
sm, xm = publish(src), publish(dst)
ledger_before = open(os.environ["EVIDENCE_LEDGER"]).read()
open(os.environ["EVIDENCE_LEDGER"], "w").close()
E.judge(sm, "accept", "", "browser")
E._write_atomic(E._admission_path("sa"), E._canon({"status": "conflicted"}))
check(not E.status(dst, xm)["judged"], "a verdict doesn't carry from a manifest whose render was revoked after judging")
E._write_atomic(E._admission_path("sa"), E._canon({"status": "admitted"}))
check(E.status(dst, xm).get("carriedFrom") == sm, "a verdict carries again once its source stands")
ours = open(os.environ["EVIDENCE_LEDGER"]).read()
open(os.environ["EVIDENCE_LEDGER"], "w").write(ledger_before + ours)
check(E.eligibility(base) == [], "a live manifest doesn't need admissions — its claim is repeatability")
retro = dict(copy.deepcopy(base), predict={"dark": "same"}, expectation="nothing changes", amends="f" * 64, retrospective=True)
check(retro["captured"]["predict"] == {"dark": "changes"} and E.observation(retro) != E.observation(base),
      "a re-explanation keeps the capture-time prediction and is its own observation")
try:
    with E._lease(os.path.join(tmp, "side")):
        with E._lease(os.path.join(tmp, "side")):
            pass
    check(False, "a second run can't take a checkout another run holds")
except E.Refused:
    check(True, "a second run can't take a checkout another run holds")
cov = dict(copy.deepcopy(base), coverage={"changed": ["a.tsx", "b.tsx"], "covered": ["a.tsx"], "uncovered": ["b.tsx"]})
cov2 = dict(copy.deepcopy(base), coverage={"changed": ["a.tsx", "b.tsx", "c.tsx"], "covered": ["a.tsx"], "uncovered": ["b.tsx", "c.tsx"]})
check(E.observation(cov) != E.observation(cov2), "a verdict doesn't carry when the change leaves more files unseen")
# ── coverage is measured: stylesheets count, and a view covers only a file its field is in ──
import subprocess  # noqa: E402
repo = os.path.join(tmp, "repo")


def sh(*a):
    return subprocess.run(["git", "-C", repo, *a], check=True, capture_output=True, text=True).stdout.strip()


def put(path, text):
    os.makedirs(os.path.dirname(os.path.join(repo, path)), exist_ok=True)
    open(os.path.join(repo, path), "w").write(text)


os.makedirs(repo)
sh("init", "-q")
sh("config", "user.email", "t@t"), sh("config", "user.name", "t")
put("components/Detail.tsx", '<input id="parent-team-id" className="a" />')
put("components/Other.tsx", '<input id="other" />')
put("styles/components/text-input.css", ".text-input { color: red }")
put("models/thing.ts", "export const x = 1")
sh("add", "-A"), sh("commit", "-qm", "before")
before = sh("rev-parse", "HEAD")
put("components/Detail.tsx", '<input id="parent-team-id" className="text-input" />')
put("components/Other.tsx", '<input id="other" className="text-input" />')
put("styles/components/text-input.css", ".text-input { color: blue }")
put("models/thing.ts", "export const x = 2")
sh("add", "-A"), sh("commit", "-qm", "after")
bb = {"beforeCommit": before, "afterCommit": sh("rev-parse", "HEAD")}
honest = {"kind": "app", "views": [{"id": "p", "field": "#parent-team-id", "file": "components/Detail.tsx"}]}
c = E.coverage(repo, bb, honest)
check("styles/components/text-input.css" in c["changed"] and "styles/components/text-input.css" in c["uncovered"],
      "a changed stylesheet is part of the change, and unseen unless a scene shows it")
check("models/thing.ts" not in c["changed"], "a non-UI file isn't part of what the evidence could show")
check(c["covered"] == ["components/Detail.tsx"], "a view covers the file its field lives in")
claims = {"kind": "app", "views": [{"id": "p", "field": "#parent-team-id", "file": "components/Other.tsx"}]}
check("components/Other.tsx" in E.coverage(repo, bb, claims)["uncovered"],
      "a view naming a file its field isn't in doesn't cover that file")
vague = E.coverage(repo, bb, {"kind": "app", "views": [{"id": "p", "field": "form input", "file": "components/Detail.tsx"}]})
check(vague["unverified"] == ["components/Detail.tsx"] and "components/Detail.tsx" in vague["uncovered"],
      "a view whose field pins nothing checkable leaves its file unverified, not covered")
# ── one subject: an edited recipe makes old evidence stale ──
E.RECIPES = os.path.join(tmp, "recipes")
os.makedirs(os.path.join(E.RECIPES, "r1"))
open(os.path.join(E.RECIPES, "r1", "recipe.json"), "w").write('{"kind": "app", "views": [{"field": "#a"}]}')
rq = {"recipe": "r1", "expectation": "e", "predict": {"*": "field"}}
bs = {"beforeTree": "bt", "afterTree": "at"}
fresh_m = {"basis": dict(bs), "recipe": {"name": "r1", "digest": E.recipe_digest("r1")}, "expectation": "e",
           "predict": {"*": "field"}}
check(E.is_current(fresh_m, rq, bs), "a manifest of these trees under this recipe and request is current")
open(os.path.join(E.RECIPES, "r1", "recipe.json"), "w").write('{"kind": "app", "views": [{"field": "#b"}]}')
check(not E.is_current(fresh_m, rq, bs), "editing the recipe in place makes its old evidence stale")
check(not E.is_current(fresh_m, dict(rq, expectation="f"), bs), "a changed expectation makes it stale")
check(not E.is_current(fresh_m, rq, dict(bs, afterTree="at2")), "a moved branch makes it stale")
# ── a verdict lands only on the evidence the branch shows right now ──
cur = publish(dict(copy.deepcopy(base), basis=dict(base["basis"], afterCommit="a9")))
orig_card = E.card
try:
    for shown, what in (({"id": cur, "current": False}, "a manifest gone stale since it was shown"),
                        ({"id": "e" * 64, "current": True}, "a manifest the branch no longer shows")):
        E.card = lambda repo, branch, s=shown: s
        try:
            E.judge_current("r", "b", cur, "accept", "", "browser")
            check(False, f"{what} can't be judged")
        except E.Refused:
            check(True, f"{what} can't be judged")
    E.card = lambda repo, branch: {"id": cur, "current": True}
    check(E.judge_current("r", "b", cur, "accept", "", "browser")["manifest"] == cur,
          "the branch's current manifest can be judged")
finally:
    E.card = orig_card
# ── reused pixels keep the prediction they were first captured under ──
first = {"expectation": "same", "predict": {"*": "same"}, "gaps": []}
edited = {"expectation": "it changes", "predict": {"*": "changes"}, "gaps": []}
fresh_sides = {"before": {"renderId": "pb", "reused": False}, "after": {"renderId": "pa", "reused": False}}
reused_sides = {"before": {"renderId": "pb", "reused": True}, "after": {"renderId": "pa", "reused": True}}
check(E.capture_binding(fresh_sides, first) == (first, None), "a fresh capture is held to the request as asked")
E.bind_capture(fresh_sides, first, "1" * 64)
check(E.capture_binding(reused_sides, first) == (first, None), "reusing pixels under the same prediction is just a capture")
check(E.capture_binding(reused_sides, edited) == (first, "1" * 64),
      "an edited prediction over reused pixels is an amendment of their first capture, not a new prediction")
half = {"before": {"renderId": "pb", "reused": True}, "after": {"renderId": "pa2", "reused": False}}
check(E.capture_binding(half, edited) == (edited, None), "new after pixels mean the prediction preceded what it predicts")
# ── the build a render attested travels with the manifest, not only the cache ──
ident_args = ("tree-x", "dg", {"node": "v"}, {"browser": "1"})
rid = E._sha(E._canon({"schema": E.SCHEMA, "tree": "tree-x", "recipe": "dg", "env": {"node": "v"}, "contract": {"browser": "1"}}))
E._write_atomic(E._admission_path(rid), E._canon({"status": "admitted", "scenes": {"s": blob(7)},
                                                   "build": {"css": "c1", "js": "j1"}}))
got = E.render("repo", "tree-x", "dg", "frozen", {"node": "v"}, {"browser": "1"}, None, log=lambda *_: None)
check(got.get("reused") and got.get("build") == {"css": "c1", "js": "j1"}, "a reused render returns the build its admission attested")
check("build" in E.side_keys(app=False) and "build" in E.side_keys(app=True), "a manifest side keeps the render's build attestation")
# ── a render sees only the environment its identity names ──
os.environ["ACCENT"] = "#ff0000"
renv = E._render_env("/donor", {"EVIDENCE_LOGIN": "x"})
check("ACCENT" not in renv, "a variable the identity doesn't name never reaches the renderer (a tailwind config can read env)")
check(renv["NODE_PATH"] == "/donor" and renv["EVIDENCE_LOGIN"] == "x" and set(renv) <= set(E.RENDER_ENV_KEYS) | {"NODE_PATH", "EVIDENCE_LOGIN"},
      "it gets the donor, the caller's explicit extras, and the named passthroughs only")
# ── one subject: a worker captures exactly the commits it was handed ──
sh("branch", "-f", "pinned", before)
pb = E.basis(repo, "pinned", pin={"before": before, "after": bb["afterCommit"]})
check((pb["beforeCommit"], pb["afterCommit"]) == (before, bb["afterCommit"]) and pb["afterTree"] == sh("rev-parse", bb["afterCommit"] + "^{tree}"),
      "a pinned basis uses the handed commits, not wherever the branch points now")
# ── owned execution: a run never serves a package build an earlier run left behind ──
side = os.path.join(tmp, "side-co")
for pkg in ("mail-pg", "prisma"):
    os.makedirs(os.path.join(side, "packages", pkg, "dist"))
    open(os.path.join(side, "packages", pkg, "dist", "index.js"), "w").write("// built for another branch")
os.makedirs(os.path.join(side, "packages", "prisma", "src"))
E._drop_builds(side)
check(not any(os.path.exists(os.path.join(side, "packages", p, "dist")) for p in ("mail-pg", "prisma"))
      and os.path.isdir(os.path.join(side, "packages", "prisma", "src")),
      "a reused checkout's package builds are dropped before serving; sources stay")
check(E._preview_failure("✓ ok\n✗ workspace package rebuild failed — this branch's packages/** changes are NOT compiled"),
      "a preview that couldn't build this tree's packages is a failure, not a warning")
check(E._preview_failure("✗ workspace package build failed — pages importing them will 500"),
      "a preview with an unbuilt package is a failure")
check(not E._preview_failure("✓ serving on 3101\n✗ pool donor is on lock abc"), "an unrelated preview warning isn't a build failure")
# ── predictions + the field rule ──
ids = ["a-light", "a-dark", "b-light"]
check(E.predictions({"predict": {"*": "field", "b-light": "same"}}, ids) == {"a-light": "field", "a-dark": "field", "b-light": "same"},
      "\"*\" covers every scene the request doesn't name")
for bad, what in (({"a-light": "same"}, "an unnamed scene with no \"*\""), ({"*": "same", "zz": "same"}, "a scene the recipe lacks"),
                  ({"*": "maybe"}, "an unknown prediction")):
    try:
        E.predictions({"predict": bad}, ids)
        check(False, f"{what} is refused")
    except E.Refused:
        check(True, f"{what} is refused")
field = [[100, 100, 200, 40]]
check(E.inside([110, 104, 50, 20], field), "a change on the field is inside it")
check(E.inside([90, 90, 220, 60], field), "a focus ring just past the field's edge still counts as the field")
check(not E.inside([100, 100, 200, 120], field), "a change that runs below the field is outside it")
check(E.inside([0, 0, 10, 10], [[0, 0, 10, 10], [200, 200, 10, 10]]) and E.inside([200, 200, 5, 5], [[0, 0, 10, 10], [200, 200, 10, 10]]),
      "a field that moved is judged against where it was on either side")
orig = E.measure
try:
    E.measure = lambda b, a, m: {"changedPixels": 5, "maxDelta": 9, "box": [110, 104, 50, 20], "size": [400, 300]}
    f = E.finding("s", "field", "x", "y", field, None)
    check(not f["departure"] and f["contained"], "a field prediction holds when only the field changed")
    E.measure = lambda b, a, m: {"changedPixels": 5, "maxDelta": 9, "box": [0, 0, 400, 300], "size": [400, 300]}
    check(E.finding("s", "field", "x", "y", field, None)["departure"], "a change past the field departs")
    E.measure = lambda b, a, m: {"changedPixels": 0, "maxDelta": 0, "box": None, "size": [400, 300], "sizeChanged": [400, 310]}
    check(E.finding("s", "field", "x", "y", field, None)["departure"], "a crop that changed size departs (something around the field moved)")
    check(E.finding("s", "field", "x", "x", field, None)["departure"], "a field predicted to change that didn't departs")
finally:
    E.measure = orig

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
