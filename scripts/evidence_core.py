"""evidence_core — rendered evidence that a branch looks the way Phil expects, as immutable records.

Design + principles: memory project_branch-proof-design.md. The shape:

  request     ~/.dotfiles/evidence/requests/<repo>/<branch>.json   which recipe, the expectation, the
              per-scene prediction ("same" | "changes") — frozen into every comparison made from it
  recipe      ~/.dotfiles/evidence/recipes/<name>/                 what to mount and which scenes; frozen
              by content digest into the cache before anything executes
  render      one tree × one recipe × one pinned environment × one renderer contract → per-scene PNGs.
              Admitted only after two independent attempts produce identical bytes; a later mismatch
              marks it conflicted and nothing reuses it
  comparison  the manifest: one captured basis (before = merge-base, after = tip, resolved once), both
              renders, the expectation, the obligations, the findings. Content-addressed, written last
  judgment    Phil's verdict on one manifest, appended to a ledger OUTSIDE the cache with the manifest's
              full contents. Written only through the viewer's Phil-only route; this module has no CLI
              path to it. A judgment carries to another manifest only when the observation is identical
              (expectation, prediction, obligations, every before/after artifact hash)

Cache (losing it costs a re-render): ~/.cache/canopy/evidence. Ledger (not cache):
~/.local/share/canopy/evidence/ledger.jsonl.
"""
import hashlib
import json
import os
import shutil
import subprocess
import time

SCHEMA = 1
HOME = os.path.expanduser("~")
DOT = os.path.join(HOME, ".dotfiles")
RECIPES = os.path.join(DOT, "evidence", "recipes")
REQUESTS = os.path.join(DOT, "evidence", "requests")
CACHE = os.environ.get("EVIDENCE_CACHE") or os.path.join(HOME, ".cache", "canopy", "evidence")
LEDGER = os.environ.get("EVIDENCE_LEDGER") or os.path.join(HOME, ".local", "share", "canopy", "evidence", "ledger.jsonl")
RENDERER = os.path.join(DOT, "scripts", "evidence-render.mjs")
MEASURE = os.path.join(DOT, "scripts", "evidence-measure.mjs")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# what the renderer imports from the donor: each must be the version the rendered tree locks
CONSUMED = ("react", "react-dom", "scheduler", "tailwindcss", "postcss", "postcss-import", "autoprefixer",
            "esbuild", "playwright")
# what tailwind scans + what the page loads; nothing else of the tree is extracted
SNAP_PATHS = ("pages", "components", "hooks", "styles", "tailwind.config.js", "postcss.config.js", "tsconfig.json")


class Refused(Exception):
    """The run can't produce evidence that would mean anything; the message says why."""


def _sha(b):
    return hashlib.sha256(b if isinstance(b, bytes) else b.encode()).hexdigest()


def _canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def _git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and r.returncode:
        raise Refused(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def _write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ── where things are ──────────────────────────────────────────────────────────────────────────

def repo_name(repo):
    common = _git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return os.path.basename(os.path.dirname(common.rstrip("/")))


def donor_modules(repo):
    """The primary checkout's node_modules — the one install every worktree borrows."""
    main = _git(repo, "worktree", "list", "--porcelain").splitlines()[0].split(" ", 1)[1]
    return os.path.realpath(os.path.join(main, "node_modules"))


def request_path(repo_id, branch):
    return os.path.join(REQUESTS, repo_id, branch.replace("/", "__") + ".json")


def load_request(repo_id, branch):
    req = _read_json(request_path(repo_id, branch))
    if not req:
        return None
    if not isinstance(req.get("predict"), dict) or not req.get("recipe") or not req.get("expectation"):
        raise Refused(f"request for {branch} needs recipe, expectation and predict")
    return req


# ── one captured basis ────────────────────────────────────────────────────────────────────────

def basis(repo, branch):
    """Every ref resolved exactly once; everything after works from these commits."""
    tip = _git(repo, "rev-parse", "--verify", f"refs/heads/{branch}^{{commit}}")
    parent = _git(repo, "config", f"branch.{branch}.stack-parent", check=False) or "main"
    base_ref = "refs/remotes/origin/main" if parent in ("main", "origin/main") else f"refs/heads/{parent}"
    base = _git(repo, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    before = _git(repo, "merge-base", base, tip)
    return {
        "branch": branch, "parent": parent, "baseRef": base_ref, "baseCommit": base,
        "beforeCommit": before, "beforeTree": _git(repo, "rev-parse", f"{before}^{{tree}}"),
        "afterCommit": tip, "afterTree": _git(repo, "rev-parse", f"{tip}^{{tree}}"),
    }


# ── frozen inputs ─────────────────────────────────────────────────────────────────────────────

def freeze_recipe(name):
    src = os.path.join(RECIPES, name)
    if not os.path.isfile(os.path.join(src, "recipe.json")):
        raise Refused(f"no recipe {name} in {RECIPES}")
    files = sorted(os.path.relpath(os.path.join(d, f), src) for d, _, fs in os.walk(src) for f in fs)
    h = hashlib.sha256()
    for rel in files:
        with open(os.path.join(src, rel), "rb") as f:
            h.update(rel.encode() + b"\0" + f.read() + b"\0")
    digest = h.hexdigest()
    frozen = os.path.join(CACHE, "recipes", digest)
    if not os.path.isdir(frozen):
        tmp = f"{frozen}.{os.getpid()}.tmp"
        shutil.copytree(src, tmp)
        try:
            os.rename(tmp, frozen)
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)
    recipe = _read_json(os.path.join(frozen, "recipe.json"))
    return digest, frozen, recipe


def snapshot(repo, tree):
    """The tree's files, extracted once into an immutable dir (`.complete` written last)."""
    d = os.path.join(CACHE, "snapshots", tree)
    if os.path.exists(os.path.join(d, ".complete")):
        return d
    present = set(_git(repo, "ls-tree", "--name-only", tree).splitlines())
    paths = [p for p in SNAP_PATHS if p in present]
    tmp = f"{d}.{os.getpid()}.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    archive = subprocess.Popen(["git", "-C", repo, "archive", tree, "--", *paths], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", tmp], stdin=archive.stdout, check=True)
    if archive.wait():
        raise Refused(f"git archive {tree} failed")
    open(os.path.join(tmp, ".complete"), "w").close()
    shutil.rmtree(d, ignore_errors=True)
    os.rename(tmp, d)
    return d


def modules_for(repo, commit, donor):
    """The immutable install built for this commit's lockfile (seed-gen's per-lockfile home, never
    mutated once .ready), else the donor when its lockfile is byte-identical; else none exists yet."""
    lock = subprocess.run(["git", "-C", repo, "show", f"{commit}:package-lock.json"], capture_output=True).stdout
    if not lock:
        raise Refused(f"{commit[:10]} has no package-lock.json")
    home = os.path.join(HOME, ".cache", "seed-gen", "nm", hashlib.md5(lock).hexdigest())
    if os.path.exists(os.path.join(home, ".ready")):
        return os.path.realpath(os.path.join(home, "node_modules")), lock
    try:
        with open(os.path.join(os.path.dirname(donor), "package-lock.json"), "rb") as f:
            if f.read() == lock:
                return donor, lock
    except OSError:
        pass
    raise Refused(f"no install for {commit[:10]}'s lockfile yet — `seed-gen --sync` in a worktree at that commit builds one")


def environment(repo, commit, donor):
    """The consumed closure, pinned before execution: each package the renderer imports must be the
    version this commit's lockfile names, or the render would be other code wearing this tree's name."""
    modules, raw = modules_for(repo, commit, donor)
    lock = json.loads(raw)
    versions = {}
    for pkg in CONSUMED:
        want = (lock.get("packages", {}).get(f"node_modules/{pkg}") or {}).get("version")
        have = (_read_json(os.path.join(modules, pkg, "package.json")) or {}).get("version")
        if not want or want != have:
            raise Refused(f"{pkg}: {commit[:10]} locks {want or 'nothing'}, {modules} has {have or 'nothing'}")
        versions[pkg] = have
    node = subprocess.run(["node", "--version"], capture_output=True, text=True).stdout.strip()
    return {"packages": versions, "node": node}, modules


def renderer_contract():
    with open(RENDERER, "rb") as f:
        code = _sha(f.read())
    chrome = subprocess.run([CHROME, "--version"], capture_output=True, text=True).stdout.strip()
    if not chrome:
        raise Refused("Google Chrome isn't installed where the renderer expects it")
    return {"renderer": code, "browser": chrome.split()[-1], "scale": 2}


# ── renders + admission ───────────────────────────────────────────────────────────────────────

def _blob(sha):
    return os.path.join(CACHE, "blobs", sha[:2], sha + ".png")


def blob_path(sha):
    """A stored artifact's file, or None. `sha` must be a bare hex digest."""
    if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
        return None
    p = _blob(sha)
    return p if os.path.exists(p) else None


def _admission_path(render_id):
    return os.path.join(CACHE, "admissions", render_id + ".json")


def _attempt(snap, frozen_recipe, donor, render_id, n, log):
    d = os.path.join(CACHE, "attempts", render_id, f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{n}")
    os.makedirs(d)
    env = {**os.environ, "NODE_PATH": donor}
    r = subprocess.run(["node", RENDERER, snap, frozen_recipe, d], env=env, capture_output=True, text=True)
    result = _read_json(os.path.join(d, "result.json"))
    if r.returncode or not result:
        why = (_read_json(os.path.join(d, "failed.json")) or {}).get("why") or r.stderr.strip()[-400:]
        raise Refused(f"render attempt {n} failed: {why}")
    log(f"  attempt {n}: {len(result['scenes'])} scenes")
    return d, result


def render(repo, tree, recipe_digest, frozen_recipe, env, contract, donor, fresh=False, log=print):
    """One admitted render: reused when admitted and every artifact is on disk, else two independent
    attempts that must match byte for byte. `fresh` re-renders an admitted identity once and checks it."""
    identity = {"schema": SCHEMA, "tree": tree, "recipe": recipe_digest, "env": env, "contract": contract}
    render_id = _sha(_canon(identity))
    adm = _read_json(_admission_path(render_id))
    if adm and adm.get("status") == "conflicted":
        raise Refused(f"render {render_id[:12]} is conflicted: {adm.get('why')}")
    have = adm and adm.get("status") == "admitted" and all(blob_path(s) for s in adm["scenes"].values())
    if have and not fresh:
        log(f"  reused admitted render {render_id[:12]}")
        return {"renderId": render_id, "scenes": adm["scenes"], "reused": True}
    snap = snapshot(repo, tree)
    runs = [_attempt(snap, frozen_recipe, donor, render_id, n, log) for n in ((1,) if have else (1, 2))]
    results = [r for _, r in runs]
    for _, r in runs:
        if r.get("browser") != contract["browser"]:
            raise Refused(f"rendered with Chrome {r.get('browser')}, pinned {contract['browser']}")
    observed = [{k: v["sha"] for k, v in r["scenes"].items()} for r in results]
    expected = adm["scenes"] if have else observed[0]
    if any(o != expected for o in observed):
        diff = sorted(k for o in observed for k in o if o.get(k) != expected.get(k))
        _write_atomic(_admission_path(render_id), _canon({
            "status": "conflicted", "renderId": render_id, "identity": identity,
            "why": f"independent attempts disagree on {', '.join(sorted(set(diff)))}",
            "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}))
        raise Refused(f"render {render_id[:12]} isn't deterministic: attempts disagree on {', '.join(sorted(set(diff)))}")
    for d, r in runs:
        for scene, s in r["scenes"].items():
            dest = _blob(s["sha"])
            if not os.path.exists(dest):
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                tmp = f"{dest}.{os.getpid()}.tmp"
                shutil.copyfile(os.path.join(d, "scenes", f"{scene}.png"), tmp)
                os.replace(tmp, dest)
    if not have:
        _write_atomic(_admission_path(render_id), _canon({
            "status": "admitted", "renderId": render_id, "identity": identity, "scenes": expected,
            "build": results[0]["build"], "attempts": [d for d, _ in runs],
            "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}))
        log(f"  admitted render {render_id[:12]} (2 attempts matched)")
    return {"renderId": render_id, "scenes": expected, "reused": False}


# ── comparison ────────────────────────────────────────────────────────────────────────────────

def _manifest_path(mid):
    return os.path.join(CACHE, "manifests", mid + ".json")


def load_manifest(mid):
    if len(mid) != 64 or any(c not in "0123456789abcdef" for c in mid):
        return None
    m = _read_json(_manifest_path(mid))
    return m if m and m.get("schema") == SCHEMA else None


def measure(before_sha, after_sha, modules):
    """Changed pixels, largest channel delta, the box around the change — a pure function of the two
    artifacts, so it can sit in the manifest without making the manifest depend on anything else."""
    r = subprocess.run(["node", MEASURE, _blob(before_sha), _blob(after_sha)], capture_output=True, text=True,
                       env={**os.environ, "NODE_PATH": modules})
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stderr.strip() or "measure failed")[-200:]}


def obligations(recipe):
    shared = {k: recipe.get(k) for k in ("component", "props", "callbacks", "valueSelector", "frame", "viewport")}
    return [{**shared, **scene} for scene in recipe["scenes"]]


def run(repo, branch, fresh=False, log=print):
    """Render and publish one comparison for <branch>; returns the manifest id."""
    repo_id = repo_name(repo)
    req = load_request(repo_id, branch)
    if not req:
        raise Refused(f"no evidence request for {branch} ({request_path(repo_id, branch)})")
    b = basis(repo, branch)
    digest, frozen, recipe = freeze_recipe(req["recipe"])
    scene_ids = [s["id"] for s in recipe["scenes"]]
    if len(set(scene_ids)) != len(scene_ids):
        raise Refused("recipe declares a scene twice")
    if set(req["predict"]) != set(scene_ids):
        raise Refused(f"the prediction must name exactly the recipe's scenes: {', '.join(scene_ids)}")
    bad = {k: v for k, v in req["predict"].items() if v not in ("same", "changes")}
    if bad:
        raise Refused(f"predict values are 'same' or 'changes': {bad}")
    donor = donor_modules(repo)
    contract = renderer_contract()
    sides = {}
    for side in ("before", "after"):
        log(f"{side}: {b[side + 'Commit'][:10]}")
        env, modules = environment(repo, b[side + "Commit"], donor)
        sides[side] = render(repo, b[side + "Tree"], digest, frozen, env, contract, modules, fresh, log)
        if set(sides[side]["scenes"]) != set(scene_ids):
            raise Refused(f"{side} render is missing scenes")
    findings = []
    for sid in scene_ids:
        b_sha, a_sha = sides["before"]["scenes"][sid], sides["after"]["scenes"][sid]
        changed = b_sha != a_sha
        predicted = req["predict"][sid]
        findings.append({"scene": sid, "predicted": predicted, "changed": changed,
                         "departure": changed != (predicted == "changes"),
                         "measure": measure(b_sha, a_sha, donor) if changed else None})
    manifest = {
        "schema": SCHEMA, "repo": repo_id, "basis": b,
        "recipe": {"name": req["recipe"], "digest": digest, "title": recipe.get("title", req["recipe"])},
        "expectation": req["expectation"], "predict": req["predict"], "obligations": obligations(recipe),
        "before": {k: sides["before"][k] for k in ("renderId", "scenes")},
        "after": {k: sides["after"][k] for k in ("renderId", "scenes")},
        "findings": findings,
    }
    text = _canon(manifest)
    mid = _sha(text)
    if not os.path.exists(_manifest_path(mid)):
        _write_atomic(_manifest_path(mid), text)
    idx = os.path.join(CACHE, "index", repo_id, branch.replace("/", "__") + ".jsonl")
    os.makedirs(os.path.dirname(idx), exist_ok=True)
    with open(idx, "a") as f:
        f.write(_canon({"id": mid, "at": time.time(), "after": b["afterCommit"]}) + "\n")
    return mid


def latest(repo_id, branch):
    idx = os.path.join(CACHE, "index", repo_id, branch.replace("/", "__") + ".jsonl")
    try:
        with open(idx) as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            mid = json.loads(line)["id"]
        except (ValueError, KeyError):
            continue
        if load_manifest(mid):
            return mid
    return None


# ── judgments ─────────────────────────────────────────────────────────────────────────────────

def observation(m):
    """What Phil saw, as one key: equal observations may share a judgment; nothing else may."""
    return _sha(_canon({k: m[k] for k in ("expectation", "predict", "obligations")}
                       | {"before": m["before"]["scenes"], "after": m["after"]["scenes"]}))


def _judgments():
    try:
        with open(LEDGER) as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def judge(mid, verdict, note, actor):
    """Append Phil's verdict on the manifest he was shown. Only the viewer's Phil-only route calls this."""
    if verdict not in ("accept", "reject"):
        raise Refused("verdict is accept or reject")
    m = load_manifest(mid)
    if not m:
        raise Refused(f"no complete manifest {mid[:12]}")
    missing = [s for side in ("before", "after") for s in m[side]["scenes"].values() if not blob_path(s)]
    if missing:
        raise Refused("some of this manifest's images are gone; re-run before judging")
    entry = {"schema": SCHEMA, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "actor": actor, "verdict": verdict,
             "note": note or "", "manifest": mid, "observation": observation(m), "contents": m}
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, "a") as f:
        f.write(_canon(entry) + "\n")
        f.flush()
        os.fsync(f.fileno())
    return entry


def status(m, mid):
    """Phil's judgment of this manifest: his own on it, else one carried from an identical observation."""
    obs = observation(m)
    exact = carried = None
    for j in _judgments():
        if j.get("manifest") == mid:
            exact = j
        elif j.get("observation") == obs:
            carried = j
    j = exact or carried
    if not j:
        return {"judged": False}
    return {"judged": True, "verdict": j["verdict"], "at": j["at"], "note": j.get("note", ""),
            "carriedFrom": None if j is exact else j["manifest"]}


def card(repo, branch):
    """Everything the branch page shows, from the current basis outward."""
    repo_id = repo_name(repo)
    try:
        req = load_request(repo_id, branch)
    except Refused as e:
        return {"request": None, "error": str(e)}
    out = {"request": req, "manifest": None, "id": None, "current": False, "status": {"judged": False}}
    mid = latest(repo_id, branch)
    if not mid:
        return out
    m = load_manifest(mid)
    try:
        b = basis(repo, branch)
        same_trees = (b["afterTree"], b["beforeTree"]) == (m["basis"]["afterTree"], m["basis"]["beforeTree"])
        same_ask = (req["recipe"], req["expectation"], req["predict"]) == (m["recipe"]["name"], m["expectation"], m["predict"])
        out["current"] = same_trees and same_ask
    except Refused:
        pass
    out.update({"manifest": m, "id": mid, "status": status(m, mid),
                "available": all(blob_path(s) for side in ("before", "after") for s in m[side]["scenes"].values())})
    return out
