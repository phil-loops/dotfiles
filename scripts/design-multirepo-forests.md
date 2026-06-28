# Multi-repo forests in the viewer — group `/forests` by repo, review inline

**Author:** handed off from the monotoad-dlq session (2026-06-28). For the viewer-lane
session — you hold `scripts/viewer-solid/`, `scripts/srv/`, `stack-review-server.py`.

## What Phil wants

On `/forests` (the Forests home tab) he currently sees only the **loops** repo's forests,
because each repo runs its own `stack-review-server` on its own hashed port (loops `:62497`,
monotoad `:62580`). He wants the list **grouped by repo** — and, when he clicks a non-loops
forest, to **review its diffs and bless inline on the same server** (he explicitly chose inline
over "jump to the other repo's port"). Concrete test case already wired: monotoad branch
`chore/dlq-redrive-link`, project `dlq-redrive`, `parent=main` in `~/coding/monotoad`.

## The core problem

Everything is pinned to one repo. `stack-review-server.py` resolves `CWD` (the launched repo)
once, and `run(args)` does `subprocess.run(..., cwd=CWD)`. That `run` is injected into every
`srv/*` handler via `srvctx.init(run=…, CWD=…)`. So model/node/diff/bless all operate on the
one repo the server booted in.

## Approach — thread-local "current repo" + a `?repo=` param

Minimal blast radius: don't thread a repo arg through every handler signature. Instead make the
*active repo* a per-request thread-local (the server is `ThreadingHTTPServer` → one thread per
request), and have `run` consult it. Existing handlers then operate on the selected repo with no
signature changes.

### Server

1. **`srv/ctx.py`** — add a thread-local repo override:
   - `import threading`; `_local = threading.local()`
   - `set_repo(path)`, `clear_repo()`, and `repo_cwd()` → `getattr(_local, "repo", None) or CWD`
   - Hot paths that read `ctx.CWD` **directly** (not via `run`) must switch to `ctx.repo_cwd()`:
     `_opened_file`, `_merges_file`, `_gh_pr` (the `cwd=ctx.CWD`), and any others in `picker.py`.
     `model_sig()` already routes through `run`, so it becomes repo-aware for free.

2. **`stack-review-server.py`** — `run(args)` uses `cwd=srvctx.repo_cwd()` instead of `cwd=CWD`.
   Build a **repo registry** at startup: `git config --get-all stack.viewer-repos` → list of repo
   roots, default `["~/coding/loops", "~/coding/monotoad"]`. For each, store
   `{ name: basename, worktree: <main worktree>, repo_id: <git-common-dir> }`. Expose a resolver
   `repo_path(name) -> worktree | None` (validated; unknown name → 400, never silent-bind).

3. **Dispatch** — in `do_GET`/`do_POST`, read `repo` from the **query string** (`?repo=<name>`;
   use query even on POSTs so you don't have to peek at JSON bodies), resolve via the registry,
   `srvctx.set_repo(path)`, dispatch inside `try/finally: srvctx.clear_repo()`. No `repo` param →
   falls back to `CWD` (fully backward compatible).

4. **`srv/picker.py` `projects()`** — aggregate: loop the registry, `set_repo` per repo, run the
   existing per-repo project build, tag each `Project` with `repo: name`, accumulate, reset.
   Include `repo` in the `_pcache` key so repos don't collide.

### Frontend

5. **`types.ts`** — add `repo: z.string()` to `Project`; add `repo` to `ForestBranch` too (keeps
   Cmd+K global jump correct across repos). Make optional-with-default if you want a softer migration.

6. **`provider.ts`** — every repo-scoped fetch needs `&repo=<current>`. Cheapest: a module-level
   "current repo" the app sets from the active route, and `HttpProvider` appends it to all URLs
   (model/node/commits/purpose/bless/standalone/…). Avoids changing each method signature.

7. **`router.tsx`** — carry repo in the forest route: `/forests/<repo>/<project>/<branch>` (so a
   deep-link / refresh into a monotoad node still resolves the right repo). Update parse + `toPath`.
   `loops` can stay the implicit default if you want short URLs for the common case.

8. **`App.tsx`** — in the Forests tab (~`:637`), group `filteredForests()` into `<For>` sections
   keyed by `repo`, each under a repo header. Links include the repo segment.

### Out of scope (loops-centric, don't bother for monotoad)

`/squash`, `/restack`, `/checkout` assume loops conventions (oxfmt/oxlint, the `~/coding/loops`
checkout). They'll still work for loops; leave them repo-naive for now — Phil wants **read +
bless** inline for other repos, not full restack/squash.

## Done = 

`:62497` `/forests` shows a **loops** group and a **monotoad** group; clicking
`dlq-redrive → chore/dlq-redrive-link` renders the `parent...branch` diff (the 5-line sqs/main.tf
change) and bless works — all without leaving `:62497`.
