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
import fcntl
import glob
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from contextlib import contextmanager

SCHEMA = 2
HOME = os.path.expanduser("~")
DOT = os.path.join(HOME, ".dotfiles")
RECIPES = os.path.join(DOT, "evidence", "recipes")
REQUESTS = os.path.join(DOT, "evidence", "requests")
CACHE = os.environ.get("EVIDENCE_CACHE") or os.path.join(HOME, ".cache", "canopy", "evidence")
LEDGER = os.environ.get("EVIDENCE_LEDGER") or os.path.join(HOME, ".local", "share", "canopy", "evidence", "ledger.jsonl")
RENDERER = os.path.join(DOT, "scripts", "evidence-render.mjs")
APP_RENDERER = os.path.join(DOT, "scripts", "evidence-app-render.mjs")
API_CAPTURE = os.path.join(DOT, "scripts", "evidence-api-capture.mjs")
LIVE_KINDS = ("app", "api")
PREVIEW = os.path.join(DOT, "scripts", "loops-preview")
PROVENANCE = os.path.join(DOT, "scripts", "loops-provenance")
APP_LOGIN = "user-1@example.com"
APP_DB = "loops-psql-1"
PREDICTIONS = ("same", "changes", "field")
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

def basis(repo, branch, pin=None):
    """Every ref resolved exactly once; everything after works from these commits. `pin` ({before,
    after} commits) hands a worker the subject someone already resolved, so it captures that one."""
    parent = _git(repo, "config", f"branch.{branch}.stack-parent", check=False) or "main"
    base_ref = "refs/remotes/origin/main" if parent in ("main", "origin/main") else f"refs/heads/{parent}"
    if pin:
        tip = _git(repo, "rev-parse", "--verify", f"{pin['after']}^{{commit}}")
        before = base = _git(repo, "rev-parse", "--verify", f"{pin['before']}^{{commit}}")
    else:
        tip = _git(repo, "rev-parse", "--verify", f"refs/heads/{branch}^{{commit}}")
        base = _git(repo, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
        before = _git(repo, "merge-base", base, tip)
    return {
        "branch": branch, "parent": parent, "baseRef": base_ref, "baseCommit": base,
        "beforeCommit": before, "beforeTree": _git(repo, "rev-parse", f"{before}^{{tree}}"),
        "afterCommit": tip, "afterTree": _git(repo, "rev-parse", f"{tip}^{{tree}}"),
    }


# ── frozen inputs ─────────────────────────────────────────────────────────────────────────────

def recipe_digest(name):
    """The recipe bundle as it reads now, as one digest over every file in it."""
    src = os.path.join(RECIPES, name)
    if not os.path.isfile(os.path.join(src, "recipe.json")):
        raise Refused(f"no recipe {name} in {RECIPES}")
    files = sorted(os.path.relpath(os.path.join(d, f), src) for d, _, fs in os.walk(src) for f in fs)
    h = hashlib.sha256()
    for rel in files:
        with open(os.path.join(src, rel), "rb") as f:
            h.update(rel.encode() + b"\0" + f.read() + b"\0")
    return h.hexdigest()


def freeze_recipe(name):
    src = os.path.join(RECIPES, name)
    digest = recipe_digest(name)
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
    return {"packages": versions, "node": node, "inherits": list(RENDER_ENV_KEYS)}, modules


def renderer_contract(renderer=RENDERER):
    with open(renderer, "rb") as f:
        code = _sha(f.read())
    if renderer == API_CAPTURE:
        with open(os.path.join(os.path.dirname(API_CAPTURE), "evidence-json.mjs"), "rb") as f:
            return {"renderer": code, "json": _sha(f.read())}
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


RENDER_ENV_KEYS = ("PATH", "HOME", "TMPDIR")


def _render_env(donor, extra=None):
    """The renderer's whole environment: the named passthroughs (node and Chrome need them), the donor,
    and the caller's explicit extras. Recipes run the tree's own tailwind config in-process, so anything
    else in os.environ could change pixels without changing the render's identity."""
    return {**{k: os.environ[k] for k in RENDER_ENV_KEYS if k in os.environ}, "NODE_PATH": donor, **(extra or {})}


def _attempt(snap, frozen_recipe, donor, render_id, n, log, renderer=RENDERER, extra_env=None):
    d = os.path.join(CACHE, "attempts", render_id, f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}-{n}")
    os.makedirs(d)
    env = _render_env(donor, extra_env)
    r = subprocess.run(["node", renderer, snap, frozen_recipe, d], env=env, capture_output=True, text=True)
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
        return {"renderId": render_id, "scenes": adm["scenes"], "identity": identity, "build": adm.get("build"),
                "frames": adm.get("frames"), "reused": True}
    snap = snapshot(repo, tree)
    runs = [_attempt(snap, frozen_recipe, donor, render_id, n, log) for n in ((1,) if have else (1, 2))]
    results = [r for _, r in runs]
    for _, r in runs:
        if r.get("browser") != contract["browser"]:
            raise Refused(f"rendered with Chrome {r.get('browser')}, pinned {contract['browser']}")
    observed = [{k: v["sha"] for k, v in r["scenes"].items()} for r in results]
    framed = [{k: v.get("frame") for k, v in r["scenes"].items()} for r in results]
    expected = adm["scenes"] if have else observed[0]
    expected_frames = adm.get("frames") if have and adm.get("frames") is not None else framed[0]
    if any(o != expected for o in observed) or any(f != expected_frames for f in framed):
        diff = sorted(k for o, f in zip(observed, framed) for k in o
                      if o.get(k) != expected.get(k) or f.get(k) != expected_frames.get(k))
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
            "build": results[0]["build"], "frames": framed[0], "attempts": [d for d, _ in runs],
            "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}))
        log(f"  admitted render {render_id[:12]} (2 attempts matched)")
    build = adm.get("build") if have else results[0]["build"]
    return {"renderId": render_id, "scenes": expected, "identity": identity, "build": build,
            "frames": expected_frames, "reused": False}


# ── app recipes: the real app, served from exactly one commit ─────────────────────────────────

def app_scenes(recipe):
    """Every view in every variant — the same expansion the app renderer makes."""
    return [{**v, **x, "id": f"{v['id']}-{x['id']}", "title": f"{v['title']}, {x['title']}", "view": v["id"],
             "viewTitle": v["title"], "variant": x["id"], "variantTitle": x["title"]}
            for v in recipe["views"] for x in recipe["variants"]]


def api_scenes(recipe):
    """Every request in every variant — the same expansion the capture script makes; no variants, one each."""
    variants = recipe.get("variants") or [None]
    return [{**r, **(x or {}), "id": f"{r['id']}-{x['id']}" if x else r["id"], "request": r["id"]}
            for r in recipe["requests"] for x in variants]


def check_api_recipe(recipe):
    """Reads only: a write changes the shared dev database that the other side and the repeat attempt read."""
    writes = [r["id"] for r in recipe.get("requests", []) if (r.get("method") or "GET").upper() != "GET"]
    if writes:
        raise Refused(f"api recipes capture GET requests only; {', '.join(writes)} would write to the dev database")


def scenes_of(recipe):
    kind = recipe.get("kind")
    return app_scenes(recipe) if kind == "app" else api_scenes(recipe) if kind == "api" else recipe["scenes"]


def _checkout(repo, side, commit, log):
    """A detached worktree pinned to `commit`, one per side, reused across runs (its .next cache and
    node_modules survive). Refuses unless HEAD is exactly that commit with nothing modified."""
    d = os.path.join(HOME, "coding", f"{repo_name(repo)}-evidence-{side}")
    if not os.path.isdir(d):
        log(f"  creating {d}")
        _git(repo, "worktree", "add", "--detach", d, commit)
    else:
        _stop(d)
        subprocess.run([PROVENANCE, d, "--revert"], capture_output=True)
        _git(d, "checkout", "--detach", "-f", commit)
    _drop_builds(d)
    head = _git(d, "rev-parse", "HEAD")
    dirty = _git(d, "status", "--porcelain", "--untracked-files=no")
    if head != commit or dirty:
        raise Refused(f"{d} isn't a clean checkout of {commit[:10]}: HEAD {head[:10]}{', modified: ' + dirty if dirty else ''}")
    return d


@contextmanager
def _lease(d):
    """Hold a side's checkout and server from checkout to teardown. The paths are shared by every
    branch's runs, so without this a second run could re-point the checkout under the first one's
    capture and have it admitted under the wrong tree."""
    os.makedirs(os.path.dirname(d), exist_ok=True)
    f = open(d + ".lease", "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        f.close()
        raise Refused(f"another evidence run holds {os.path.basename(d)} — try again when it finishes")
    try:
        f.write(f"{os.getpid()}\n")
        f.flush()
        yield
    finally:
        fcntl.flock(f, fcntl.LOCK_UN)
        f.close()


def busy(repo):
    """Whether any run holds an evidence checkout right now (CLI runs included, not just the viewer's)."""
    for side in ("before", "after"):
        try:
            with _lease(os.path.join(HOME, "coding", f"{repo_name(repo)}-evidence-{side}")):
                pass
        except Refused:
            return True
    return False


def _stop(d):
    subprocess.run([PREVIEW, d, "--kill"], capture_output=True)


def _drop_builds(d):
    """Remove the checkout's workspace package builds. They're gitignored, so a checkout survives with
    the last run's — possibly rebuilt against another branch's packages — and loops-preview, which
    only rebuilds what it freshly borrows, would serve them."""
    for dist in glob.glob(os.path.join(d, "packages", "*", "dist")):
        shutil.rmtree(dist, ignore_errors=True)


PREVIEW_BUILD_FAILURES = ("workspace package rebuild failed", "workspace package build failed")


def _preview_failure(output):
    """The line where loops-preview said it is serving code other than this tree's, if any."""
    return next((line for line in output.splitlines() if any(f in line for f in PREVIEW_BUILD_FAILURES)), None)


def _serve(d, log, timeout=1500):
    """Start a preview of checkout `d` and wait until it answers; returns its base URL."""
    # one evidence server at a time, on top of whatever other sessions run: room for exactly one more
    running = len(json.loads(subprocess.run([PREVIEW, "--json"], capture_output=True, text=True).stdout or "[]"))
    env = {**os.environ, "LOOPS_PREVIEW_NO_BADGE": "1", "LOOPS_PREVIEW_MAX": str(max(3, running + 1))}
    r = subprocess.run([PREVIEW, d], env=env, capture_output=True, text=True)
    if r.returncode:
        raise Refused(f"loops-preview {d} failed: {(r.stderr or r.stdout).strip()[-400:]}")
    failed = _preview_failure(r.stdout + "\n" + r.stderr)
    if failed:
        _stop(d)
        raise Refused(f"{os.path.basename(d)} would serve code that isn't this tree's: {failed.strip()}")
    listed = json.loads(subprocess.run([PREVIEW, "--json"], capture_output=True, text=True).stdout or "[]")
    port = next((p["port"] for p in listed if p.get("dir") == d), None)
    if not port:
        raise Refused(f"loops-preview started no server for {d}")
    base = f"http://localhost:{port}"
    log(f"  serving {os.path.basename(d)} at {base}; waiting for it to compile")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/api/auth/csrf", timeout=120) as resp:
                if resp.status == 200 and b"csrfToken" in resp.read():
                    return base
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(5)
    raise Refused(f"{base} never answered within {timeout}s")


def _env_value(d, key):
    for name in (".env.development.local", ".env.local", ".env.development", ".env"):
        try:
            with open(os.path.join(d, name)) as f:
                for line in reversed(f.read().splitlines()):
                    if line.strip().startswith(key + "="):
                        return line.split("=", 1)[1].split(" #")[0].strip().strip("\"'")
        except OSError:
            continue
    return None


def _login_token(d):
    """A one-use magic-link token for the dev user, stored the way next-auth's adapter stores one."""
    secret = _env_value(d, "NEXTAUTH_SECRET")
    if not secret:
        raise Refused(f"{d} has no NEXTAUTH_SECRET")
    token = secrets.token_hex(32)
    hashed = hashlib.sha256((token + secret).encode()).hexdigest()
    sql = ("insert into \"VerificationToken\" (id, identifier, token, expires) values "
           f"('evidence-{secrets.token_hex(8)}', '{APP_LOGIN}', '{hashed}', now() + interval '15 minutes')")
    r = subprocess.run(["docker", "exec", APP_DB, "psql", "-U", "postgres", "-At", "-c", sql], capture_output=True, text=True)
    if r.returncode:
        raise Refused(f"couldn't store a sign-in token: {r.stderr.strip()[-200:]}")
    return json.dumps({"email": APP_LOGIN, "token": token})


def app_render(repo, side, commit, tree, recipe_digest, frozen_recipe, contract, donor, nonce, log=print,
               renderer=APP_RENDERER, kind="app"):
    """Both attempts against one server for this commit, then the server goes away. Never reused by a
    later run: the database isn't part of the identity, so only captures from one run share their data."""
    lock = subprocess.run(["git", "-C", repo, "show", f"{commit}:package-lock.json"], capture_output=True).stdout
    main = _git(repo, "worktree", "list", "--porcelain").splitlines()[0].split(" ", 1)[1]
    main_head = _git(main, "rev-parse", "HEAD")
    own_packages = bool(_git(repo, "diff", "--name-only", main_head, commit, "--", "packages/", check=False))
    env = {"lock": hashlib.md5(lock).hexdigest(), "packagesFrom": main_head,
           # loops-preview borrows main's built workspace packages unless this tree's differ (then it rebuilds)
           "packages": "rebuilt from this tree" if own_packages else "borrowed: main's build, unverified against main's sources",
           "db": "local dev database", "user": APP_LOGIN}
    identity = {"schema": SCHEMA, "kind": kind, "tree": tree, "recipe": recipe_digest, "env": env,
                "contract": contract, "run": nonce}
    render_id = _sha(_canon(identity))
    d = os.path.join(HOME, "coding", f"{repo_name(repo)}-evidence-{side}")
    with _lease(d):
        d = _checkout(repo, side, commit, log)
        try:
            base = _serve(d, log)
            served = _git(d, "rev-parse", "HEAD")
            if served != commit:
                raise Refused(f"{d} served {served[:10]}, not {commit[:10]}")
            runs = [_attempt(base, frozen_recipe, donor, render_id, n, log, renderer, {"EVIDENCE_LOGIN": _login_token(d)})
                    for n in (1, 2)]
        finally:
            _stop(d)
    results = [r for _, r in runs]
    for r in results:
        if contract.get("browser") and r.get("browser") != contract["browser"]:
            raise Refused(f"rendered with Chrome {r.get('browser')}, pinned {contract['browser']}")
    observed = [{k: v["sha"] for k, v in r["scenes"].items()} for r in results]
    framed = [{k: v.get("frame") for k, v in r["scenes"].items()} for r in results]
    if observed[0] != observed[1] or framed[0] != framed[1]:
        diff = sorted(k for k in observed[0] if observed[0][k] != observed[1].get(k) or framed[0].get(k) != framed[1].get(k))
        _write_atomic(_admission_path(render_id), _canon({
            "status": "conflicted", "renderId": render_id, "identity": identity,
            "why": f"independent attempts disagree on {', '.join(diff)}", "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}))
        raise Refused(f"{side} capture isn't repeatable: attempts disagree on {', '.join(diff)} — mask what moves")
    for dd, r in runs[:1]:
        for scene, s in r["scenes"].items():
            dest = _blob(s["sha"])
            if not os.path.exists(dest):
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                tmp = f"{dest}.{os.getpid()}.tmp"
                shutil.copyfile(os.path.join(dd, "scenes", s.get("file") or f"{scene}.png"), tmp)
                os.replace(tmp, dest)
    fields = {k: v.get("field") for k, v in results[0]["scenes"].items()}
    at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    _write_atomic(_admission_path(render_id), _canon({
        "status": "repeatable", "renderId": render_id, "identity": identity, "scenes": observed[0], "fields": fields,
        "frames": framed[0], "attempts": [dd for dd, _ in runs], "at": at}))
    log(f"  {side} capture {render_id[:12]} repeated (2 captures matched)")
    return {"renderId": render_id, "scenes": observed[0], "fields": fields, "frames": framed[0],
            "identity": identity, "capturedAt": at, "reused": False}


def inside(box, fields, slack=16):
    """Whether a change box (device px) lies within the union of the field's boxes, give or take a focus ring."""
    xs = [f[0] for f in fields] + [f[0] + f[2] for f in fields]
    ys = [f[1] for f in fields] + [f[1] + f[3] for f in fields]
    x0, y0, x1, y1 = min(xs) - slack, min(ys) - slack, max(xs) + slack, max(ys) + slack
    return box[0] >= x0 and box[1] >= y0 and box[0] + box[2] <= x1 and box[1] + box[3] <= y1


# ── comparison ────────────────────────────────────────────────────────────────────────────────

def _manifest_path(mid):
    return os.path.join(CACHE, "manifests", mid + ".json")


def load_manifest(mid):
    if len(mid) != 64 or any(c not in "0123456789abcdef" for c in mid):
        return None
    m = _read_json(_manifest_path(mid))
    return m if m and m.get("schema") in (1, SCHEMA) else None


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
    if recipe.get("kind") == "api":
        return api_scenes(recipe)
    if recipe.get("kind") == "app":
        return [{k: v for k, v in sc.items()} | {"viewport": recipe.get("viewport")} for sc in app_scenes(recipe)]
    shared = {k: recipe.get(k) for k in ("component", "props", "callbacks", "valueSelector", "frame", "viewport")}
    return [{**shared, **scene} for scene in recipe["scenes"]]


def predictions(req, scene_ids):
    """The request's per-scene prediction; "*" covers every scene it doesn't name."""
    p = dict(req["predict"])
    default = p.pop("*", None)
    unknown = set(p) - set(scene_ids)
    if unknown:
        raise Refused(f"the prediction names scenes the recipe doesn't have: {', '.join(sorted(unknown))}")
    missing = [s for s in scene_ids if s not in p and default is None]
    if missing:
        raise Refused(f"no prediction for {', '.join(missing)} (name each, or give \"*\")")
    out = {s: p.get(s, default) for s in scene_ids}
    bad = {k: v for k, v in out.items() if not (v in PREDICTIONS or _paths_prediction(v))}
    if bad:
        raise Refused(f"predict values are {', '.join(PREDICTIONS)} or {{\"paths\": [\"$.…\"]}}: {bad}")
    return out


def _paths_prediction(v):
    return (isinstance(v, dict) and set(v) == {"paths"} and isinstance(v["paths"], list) and v["paths"]
            and all(isinstance(p, str) and p.startswith("$") for p in v["paths"]))


def json_diff(a, b, path="$"):
    """Every path where `a` and `b` differ, leaf by leaf: changed, added (absent before) or removed."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}"
            if k not in a:
                out.append({"path": p, "before": None, "after": b[k], "added": True})
            elif k not in b:
                out.append({"path": p, "before": a[k], "after": None, "removed": True})
            else:
                out += json_diff(a[k], b[k], p)
        return out
    if isinstance(a, list) and isinstance(b, list):
        out = []
        for i in range(max(len(a), len(b))):
            p = f"{path}[{i}]"
            if i >= len(a):
                out.append({"path": p, "before": None, "after": b[i], "added": True})
            elif i >= len(b):
                out.append({"path": p, "before": a[i], "after": None, "removed": True})
            else:
                out += json_diff(a[i], b[i], p)
        return out
    return [] if a == b else [{"path": path, "before": a, "after": b}]


def _under(path, declared):
    """Whether `path` is `declared` or inside it; `[*]` in `declared` matches any index."""
    pattern = re.escape(declared).replace(re.escape("[*]"), r"\[\d+\]")
    return re.fullmatch(pattern + r"(?:[.\[].*)?", path) is not None


def _clip(v, n=200):
    text = json.dumps(v)
    return v if len(text) <= n else text[:n] + "…"


def api_finding(sid, predicted, b_sha, a_sha):
    """One request's outcome against its prediction, from the two captured artifacts. A paths prediction
    holds when the status is unchanged and every difference lies inside a declared body path."""
    before, after = _read_json(_blob(b_sha)), _read_json(_blob(a_sha))
    diff = [] if b_sha == a_sha else json_diff(before, after)
    changed = bool(diff)
    if _paths_prediction(predicted):
        declared = ["$.body" + p[1:] for p in predicted["paths"]]
        outside = [d["path"] for d in diff if not any(_under(d["path"], p) for p in declared)]
        departure = not changed or bool(outside)
    else:
        outside = []
        departure = changed != (predicted == "changes")
    return {"scene": sid, "predicted": predicted, "changed": changed, "departure": departure,
            "status": [before.get("status"), after.get("status")], "outside": outside,
            "diff": [{**d, "before": _clip(d["before"]), "after": _clip(d["after"])} for d in diff[:50]],
            "diffCount": len(diff)}


def _placement(frame):
    return frame and (frame.get("crop"), frame.get("viewport"), frame.get("scroll"))


def finding(sid, predicted, b_sha, a_sha, fields, modules, frames=None):
    """One scene's outcome against its prediction. `frames` (before, after) are where each picture sat
    on the page: identical pixels in a new place moved, and a move is a change."""
    changed = b_sha != a_sha
    moved = bool(frames and frames[0] and frames[1] and _placement(frames[0]) != _placement(frames[1]))
    m = measure(b_sha, a_sha, modules) if changed else None
    if predicted == "field":
        ok = changed and not moved and bool(m) and not m.get("sizeChanged") and bool(m.get("box")) and inside(m["box"], fields)
        departure = not ok
    else:
        departure = (changed or moved) != (predicted == "changes")
    out = {"scene": sid, "predicted": predicted, "changed": changed, "moved": moved, "departure": departure, "measure": m}
    if predicted == "field" and changed:
        out["contained"] = not departure
    return out


def run(repo, branch, fresh=False, log=print, pin=None):
    """Render and publish one comparison for <branch> (of the pinned commits when given); returns the manifest id."""
    repo_id = repo_name(repo)
    req = load_request(repo_id, branch)
    if not req:
        raise Refused(f"no evidence request for {branch} ({request_path(repo_id, branch)})")
    b = basis(repo, branch, pin)
    digest, frozen, recipe = freeze_recipe(req["recipe"])
    kind = recipe.get("kind")
    app = kind in LIVE_KINDS
    if kind == "api":
        check_api_recipe(recipe)
    scene_ids = [s["id"] for s in scenes_of(recipe)]
    if len(set(scene_ids)) != len(scene_ids):
        raise Refused("recipe declares a scene twice")
    predict = predictions(req, scene_ids)
    donor = donor_modules(repo)
    renderer = API_CAPTURE if kind == "api" else APP_RENDERER if app else RENDERER
    contract = renderer_contract(renderer)
    nonce = secrets.token_hex(8)
    sides = {}
    for side in ("before", "after"):
        log(f"{side}: {b[side + 'Commit'][:10]}")
        if app:
            sides[side] = app_render(repo, side, b[side + "Commit"], b[side + "Tree"], digest, frozen, contract,
                                     donor, nonce, log, renderer=renderer, kind=kind)
        else:
            env, modules = environment(repo, b[side + "Commit"], donor)
            sides[side] = render(repo, b[side + "Tree"], digest, frozen, env, contract, modules, fresh, log)
        if set(sides[side]["scenes"]) != set(scene_ids):
            raise Refused(f"{side} render is missing scenes")
    captured, amends = capture_binding(sides, _asked(req))
    if amends:
        log(f"  both renders reused from {amends[:12]}, first captured under another prediction — publishing an amendment")
    mid = publish(repo, branch, b, req, digest, recipe, sides, donor, captured=captured, amends=amends)
    bind_capture(sides, captured, mid)
    return mid


def _binding_path(sides):
    pair = sides["before"]["renderId"] + ":" + sides["after"]["renderId"]
    return os.path.join(CACHE, "bindings", _sha(pair) + ".json")


def bind_capture(sides, captured, mid):
    """Remember the prediction a render pair was first published under; later binds never replace it."""
    path = _binding_path(sides)
    if not os.path.exists(path):
        _write_atomic(path, _canon({"captured": captured, "manifest": mid}))


def capture_binding(sides, asked):
    """(prediction the capture is held to, manifest it amends or None). When both sides reuse pixels
    already published, Phil may have seen them: a prediction that differs from the one they were first
    captured under is a retrospective amendment of that capture, never a new prediction."""
    if not all(sides[s].get("reused") for s in ("before", "after")):
        return asked, None
    first = _read_json(_binding_path(sides))
    if not first or first["captured"] == asked:
        return asked, None
    return first["captured"], first["manifest"]


def _asked(req):
    """What a request asked at capture time — the prediction a capture is held to, forever."""
    return {"expectation": req["expectation"], "predict": req["predict"], "gaps": req.get("gaps", [])}


def restate(repo, branch, log=print):
    """Re-explain the latest captures under the request as it reads now. The result is an AMENDMENT:
    it names the manifest it re-explains, is marked retrospective, and keeps the prediction the
    captures were made under — a new story told after seeing the pixels never passes for a prediction.
    Refused unless the trees and recipe are exactly what those captures were made from."""
    repo_id = repo_name(repo)
    req = load_request(repo_id, branch)
    if not req:
        raise Refused(f"no evidence request for {branch}")
    mid = latest(repo_id, branch)
    if not mid:
        raise Refused(f"nothing captured for {branch} yet — run it first")
    m = load_manifest(mid)
    why = eligibility(m)
    if why:
        raise Refused(f"can't re-explain {mid[:12]}: {'; '.join(why)}")
    b = basis(repo, branch)
    if (b["beforeTree"], b["afterTree"]) != (m["basis"]["beforeTree"], m["basis"]["afterTree"]):
        raise Refused("the branch or its base moved since the capture — run it again")
    digest, _, recipe = freeze_recipe(req["recipe"])
    if req["recipe"] != m["recipe"]["name"] or digest != m["recipe"]["digest"]:
        raise Refused("the recipe changed since the capture — run it again")
    log(f"re-explaining {mid[:12]} under the current request (retrospective)")
    sides = {s: m[s] for s in ("before", "after")}
    return publish(repo, branch, b, req, digest, recipe, sides, donor_modules(repo),
                   captured=m["captured"], amends=mid)


UI_ROOTS = ("components/", "pages/", "app/", "hooks/", "styles/")
STYLE_EXTS = (".css", ".scss", ".pcss")
STYLE_CONFIGS = ("tailwind.config.js", "tailwind.config.ts", "postcss.config.js", "postcss.config.mjs")


API_ROOTS = ("pages/api/", "app/api/", "trpc/", "models/", "queries/")


def _api_file(p):
    return p.startswith(API_ROOTS) and p.endswith((".ts", ".tsx")) and not p.endswith((".test.ts", ".test.tsx"))


def _ui_file(p):
    if p.endswith(STYLE_EXTS) or p in STYLE_CONFIGS:
        return True
    return p.startswith(UI_ROOTS) and p.endswith((".tsx", ".ts")) and not p.endswith((".test.ts", ".test.tsx"))


def _anchors(selector):
    """The literals a field selector pins (#ids, attribute values) — what must appear in a file's
    source for a view to be looking at it."""
    ids = re.findall(r"#([\w-]+)", selector or "")
    quoted = re.findall(r"=\s*\"([^\"]+)\"|=\s*'([^']+)'", selector or "")
    return ids + [d or s for d, s in quoted]


def coverage(repo, b, recipe):
    """Which UI files the change touches, and which of them a scene looks at — measured from the
    diff, not declared. A view covers its named file only when its field's anchors appear in that
    file's after-side source; one with no anchor to check is unverified. What's uncovered is what
    accepting the evidence accepts without seeing."""
    kind = recipe.get("kind")
    shows = _api_file if kind == "api" else _ui_file
    changed = {p for p in _git(repo, "diff", "--name-only", b["beforeCommit"], b["afterCommit"]).splitlines()
               if shows(p)}
    unverified = set()
    if kind in LIVE_KINDS:
        looked = set()
        for v in recipe["requests" if kind == "api" else "views"]:
            f = v.get("file")
            if not f or f not in changed:
                continue
            anchors = [v["anchor"]] if v.get("anchor") else _anchors(v.get("field"))
            if not anchors:
                unverified.add(f)
                continue
            src = _git(repo, "show", f"{b['afterCommit']}:{f}", check=False)
            if any(a in src for a in anchors):
                looked.add(f)
        unverified -= looked
    else:
        looked = {recipe["component"]["file"]}
    return {"changed": sorted(changed), "covered": sorted(changed & looked), "uncovered": sorted(changed - looked),
            "unverified": sorted(unverified)}


def side_keys(app):
    """What a manifest keeps of each side's render: identity and attested build travel with it, so the
    ledger can say what produced an accepted picture after the cache lets the admission go."""
    return ("renderId", "scenes", "identity", "build", "frames") + (("fields", "capturedAt") if app else ())


def publish(repo, branch, b, req, digest, recipe, sides, donor, captured, amends=None):
    repo_id = repo_name(repo)
    app = recipe.get("kind") in LIVE_KINDS
    scene_ids = [s["id"] for s in scenes_of(recipe)]
    predict = predictions(req, scene_ids)
    findings = []
    for sid in scene_ids:
        if recipe.get("kind") == "api":
            findings.append(api_finding(sid, predict[sid], sides["before"]["scenes"][sid], sides["after"]["scenes"][sid]))
            continue
        fields = [sides[s].get("fields", {}).get(sid) for s in ("before", "after")]
        findings.append(finding(sid, predict[sid], sides["before"]["scenes"][sid], sides["after"]["scenes"][sid],
                                [f for f in fields if f], donor,
                                frames=tuple((sides[s].get("frames") or {}).get(sid) for s in ("before", "after"))))
    keep = side_keys(app)
    manifest = {
        "schema": SCHEMA, "repo": repo_id, "basis": b,
        # what kind of claim this is: a closed, independently admitted render, or captures from live
        # local previews under a shared, mutable dev environment (repeatable, not reproducible)
        "claim": "live" if app else "deterministic",
        "recipe": {"name": req["recipe"], "digest": digest, "title": recipe.get("title", req["recipe"]),
                   "kind": recipe.get("kind", "component")},
        "captured": captured,
        "expectation": req["expectation"], "predict": req["predict"], "obligations": obligations(recipe),
        "gaps": req.get("gaps", []),
        "coverage": coverage(repo, b, recipe),
        "amends": amends, "retrospective": amends is not None,
        "before": {k: sides["before"][k] for k in keep if k in sides["before"]},
        "after": {k: sides["after"][k] for k in keep if k in sides["after"]},
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


def eligibility(m):
    """Why this manifest can't be judged, carried or re-explained — empty when it can. The one check
    every consumer uses (card, judge, carry, restate), so none of them can be more lenient."""
    if not m:
        return ["no such manifest"]
    if m.get("schema") != SCHEMA:
        return ["recorded by an older engine without its framing or claim class — render it again"]
    why = []
    if any(not blob_path(sha) for side in ("before", "after") for sha in m[side]["scenes"].values()):
        why.append("some of its images are gone from the cache — render it again")
    if m.get("claim") == "deterministic":
        for side in ("before", "after"):
            adm = _read_json(_admission_path(m[side]["renderId"])) or {}
            if adm.get("status") != "admitted":
                why.append(f"its {side} render is {adm.get('status') or 'no longer admitted'}")
    return why


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
    """What Phil saw, as one key: equal observations may share a judgment; nothing else may. From
    schema 2 that includes where every picture sat on the page and what kind of claim it is, so a
    dialog that moved can't carry a verdict given to it in its old place."""
    key = ({k: m[k] for k in ("expectation", "predict", "obligations")}
           | {"before": m["before"]["scenes"], "after": m["after"]["scenes"]}
           | ({"gaps": m["gaps"]} if m.get("gaps") else {}))
    if m.get("schema", 1) >= 2:
        key |= {"schema": m["schema"], "claim": m["claim"], "captured": m["captured"], "coverage": m.get("coverage"),
                "framing": {side: {k: m[side].get(k) for k in ("fields", "frames")} for side in ("before", "after")}}
    return _sha(_canon(key))


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
    why = eligibility(m)
    if why:
        raise Refused(f"can't judge {mid[:12]}: {'; '.join(why)}")
    entry = {"schema": SCHEMA, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "actor": actor, "verdict": verdict,
             "note": note or "", "manifest": mid, "observation": observation(m), "contents": m}
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, "a") as f:
        f.write(_canon(entry) + "\n")
        f.flush()
        os.fsync(f.fileno())
    return entry


def judge_current(repo, branch, mid, verdict, note, actor):
    """Judge `mid` only while it is the evidence `branch` shows for its current subject: the click
    names what Phil saw, and a sync or request edit since then makes it a different question."""
    shown = card(repo, branch)
    if shown.get("id") != mid:
        raise Refused(f"{branch} no longer shows {mid[:12]} — look again")
    if not shown.get("current"):
        raise Refused(f"{mid[:12]} is of older code or an older request than {branch} has now — look again")
    return judge(mid, verdict, note, actor)


def status(m, mid):
    """Phil's judgment of this manifest: his own on it, else one carried from an identical observation.
    Eligibility is checked now, not only at judging: a verdict on a manifest that has since become
    ineligible (a revoked render, lost images) is reported but doesn't stand, and nothing carries onto
    or from one."""
    why = eligibility(m)
    obs = observation(m)
    exact = carried = None
    for j in _judgments():
        if j.get("manifest") == mid:
            exact = j
        elif j.get("observation") == obs and not why and not eligibility(j.get("contents")):
            carried = j
    j = exact or carried
    if not j:
        return {"judged": False}
    return {"judged": True, "verdict": j["verdict"], "at": j["at"], "note": j.get("note", ""),
            "carriedFrom": None if j is exact else j["manifest"], "stands": not why, "why": why}


def is_current(m, req, b):
    """Whether manifest `m` is evidence of this subject: the same trees, the request as it reads now,
    and the recipe bundle as it reads now (an edited recipe is a different question)."""
    same_trees = (b["afterTree"], b["beforeTree"]) == (m["basis"]["afterTree"], m["basis"]["beforeTree"])
    same_ask = ((req["recipe"], req["expectation"], req["predict"], req.get("gaps", []))
                == (m["recipe"]["name"], m["expectation"], m["predict"], m.get("gaps", [])))
    return same_trees and same_ask and m["recipe"].get("digest") == recipe_digest(req["recipe"])


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
        out["basis"] = b
        out["current"] = is_current(m, req, b)
    except Refused:
        pass
    why = eligibility(m)
    out.update({"manifest": m, "id": mid, "status": status(m, mid), "eligible": not why, "why": why,
                "available": all(blob_path(s) for side in ("before", "after") for s in m[side]["scenes"].values())})
    return out
