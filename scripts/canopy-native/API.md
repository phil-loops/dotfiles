# canopy HTTP contract (v2 frontend ↔ Python server)

For porting `scripts/viewer-solid/src/v2/` to a native macOS client that talks to the unchanged
`scripts/stack-review-server.py`. Sources read 2026-10-29; shapes marked *(live)* were confirmed with a
GET against a running server. Everything else is read from the handler code (file:function given).
Full TS types for the store entities live in `viewer-solid/src/v2/types.ts`; read that alongside this.

## Basics

- **Bind**: `127.0.0.1`, one server per repo registry. Port: `stack-review-port [repo]` (derived from the
  git common dir; `$STACK_REVIEW_PORT` wins; legacy default 62333).
- **Unsupervised servers self-reap after 15 min idle.** Any request resets the clock, and so does an open
  `/events` or `/v2/events` stream.
- **Every response** carries `Cache-Control: no-store`. JSON bodies are `application/json`. Unknown GET →
  `404 {}`, unless the request sends `Accept: text/html`, which gets a 302 to home. Unknown POST → `404 {}`.
- **Request headers the web client sends** (`sync.ts` `headers()`):
  - `X-Stack-Actor`: one of `browser|claude|extension|cli|headless|helix|server|unknown`. The web app sends
    `browser` (or `headless` under webdriver). Without the header, the server classifies the caller by
    Origin or User-Agent (`srv/actor.py classify`). For a CLI-shaped UA it also walks the peer process.
    The actor ends up in the request log, the usage log and git hooks (`STACK_ACTOR` env). It is also part
    of the GitHub-write gate (see Refusals).
  - `X-Request-Id`: `<pageLoadId>-<seq>`. The server writes it to its request log.
  - `X-Stack-Session` (optional): a Claude session id prefix. The web app never sends it.
  - On writes only: `X-Stack-Via: key|click|menu|palette|…` names the gesture (`runner.ts` passes `via` to
    `post()`).
  - POSTs send `Content-Type: application/json` with a JSON body.
- **Origin check (POST only)**: a POST carrying an `Origin` header that isn't `http(s)://localhost|127.0.0.1[:port]`
  (or the gh-to-nvim extension's id) gets `403 {"ok":false,"err":"cross-origin POST rejected"}`. A native
  client that omits `Origin` passes this check.
- **After every POST** the server drops its repo snapshot cache and pokes the v2 state refresher, so the
  patch for a write goes out right away, not on the next 0.5 s tick.

### The repo prefix

The server serves several repos (`git config stack.viewer-repos`, default `~/coding/loops` and
`~/coding/monotoad`). Each registry name is the basename of its root.

- A request path of `/<repo>/<rest>` pins the request thread to that repo and dispatches on `/<rest>`
  (`_enter_repo`). This holds for both GET and POST.
- A path with no prefix runs against the server's launch repo (CWD).
- Prefixing only applies when the first segment is a registry name. `/v2/...` is never stripped.
- The client helpers `atRepo` (`model.ts`) and `atRepoPath` (`review/page.ts`, aliased `repoPath` in
  `commands/review.ts`) are the same function. They prefix only when the repo is in
  `window.__VIEWER_REPOS__`, an array the server injects into the `/v2` HTML shell. `__CANOPY_KEYS__` (the
  keymap) and `__CANOPY_ASSET__` (the build signature) are injected the same way.
- **Native port**: no JSON endpoint returns the registry. Two ways to get it:
  - Take the `repo` entity ids from `/state`, which are the same names.
  - Scrape the injected `<script>` from `GET /v2`, which is also the only way to get the keymap.
- Which calls carry a prefix is noted per row below: **[R]** means prefixed, **[—]** means unprefixed (a
  global or default-repo call, or repo passed in the body).

### Refusals and the write envelope (`sync.ts post()`, server `H._send`)

- **Success**: a write succeeds when the status is 2xx **and** the body does not have `ok === false`.
- **Refusal at 200**: a POST answered `200` whose JSON body has `"ok": false` is a refusal. The server adds
  the header `X-Stack-Refused: <slug>`, a short stable class taken from the body's `err` (or `error`) by
  `reqlog.error_class`, e.g. `no-such-branch`. The header is only added on POST, only for JSON bodies under
  64 KB, and only when the body starts with `{`.
- **Client outcome mapping**:

  | Response | Outcome |
  |---|---|
  | 2xx with `ok:false` | `refused` |
  | 4xx | `refused` |
  | 5xx | `failed` |
  | fetch threw | `failed`, err `network` |

  The client shows the body's `err` as the user-facing reason when it is a string of 140 characters or
  less. Otherwise it shows the header slug.
- **Two error keys**: handlers use `err` in most places and `error` in some (`/focus`, `/project-state`,
  `/viewed`, `/todo-item`, `/landed-why`, `/model`). Read both.
- **Non-200 statuses used on refusal**: 400 (bad input), 404 (no such branch or worktree), 409 (state
  conflict: `/sync`, `/restack`, `/reconcile`, `/revert-commit`), 500 (a subprocess failed), 504 (`/open`
  with a wedged editor). `/reseat-children` answers **207** with `ok:false` when there are conflicts.
- **GitHub-write gate** (`srv/ghreview.py refusal()`): applies to `/review-draft` with `send` or
  `op:"send"`, i.e. anything that goes into Phil's pending GitHub review. The write is refused, answered as
  `200 {ok:false, err}`, unless **all** of these hold:
  - not the sandbox;
  - `git config stack.viewer-github-pending true`;
  - the actor is exactly `browser`;
  - `X-Stack-Via` is one of `key|click|menu|palette`;
  - **`Sec-Fetch-Site: same-origin`**.

  A native client must send `X-Stack-Actor: browser`, an `X-Stack-Via` gesture and
  `Sec-Fetch-Site: same-origin` explicitly, or every GitHub send stays a local draft.
  - A second gate, `scope_refusal`: until `stack.viewer-github-scope all`, only replies on threads opened
    by `john-hankles` go to GitHub.
  - The only mutations ever sent are: `addPullRequestReview` (no `event`, so the review stays PENDING),
    `addPullRequestReviewThread`, and `addPullRequestReviewThreadReply`.
- **"Read" POSTs**: `ask()` uses POST for reads (the LSP routes and `/integrate`) and returns `null` on a
  non-2xx response.
- **Optimistic writes**: writes queue FIFO on the client (`runner.ts`), except a write marked `alone`
  (`/delta-tests`). The client keeps its overlay until the store patch arrives, or for 5 s.

---

## 1. Store and sync

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `GET /state` [—] | READ | `?archived=1` also returns the branches and PRs of archived projects. Archived *projects* are always listed. | *(live)* `{epoch, versions:{git,remote,review,todo}, entities:{repo,project,branch,pr,landed,warm,conv,thread,draft,viewed,todo: {id: obj}}, ms}`. See "Entities" below. Calls `refresh()` synchronously first. | `sync.ts load()`; `Menu.tsx` (`?archived=1`, the finder) |
| `GET /v2/events` [—] | READ, SSE | `?epoch=E&git=N&remote=N&review=N&todo=N[&archived=1]`. A missing version means "I'm current". | See "/v2/events" below. | `sync.ts open()` |
| `GET /events` [—] | READ, SSE | none | The v1 pulse. Starts with `: connected`; `: ping` every 5 s. Events: `reload` (data `1`, the build changed), `update` (data `1`, the forest or remote moved), `procs` (data `1`, previews/agents/chat turns moved), `stale` (`{failing, age}`, origin checks broken or recovered). **v2 listens only to `procs`.** It holds the stream open only while a `onProcs` subscriber exists and the tab is visible. | `sync.ts openPulse()`. Subscribers: `workstation.ts` (refetches `/previews`) |
| `POST /track` [—] | MUTATING (appends `.git/stack-usage.jsonl`) | `{type:"batch", events:[{schema:2, app:"v2", pl, type, …}]}` or a single event. Up to `BATCH_MAX` per batch. The server stamps `ts` and `actor` (from the request, never the body). | always `{"ok":true}` | `telemetry.ts flush()` (every 3 s; `sendBeacon` on hide, which sends no `X-Stack-Actor`, so the UA classifies it) |

### `/v2/events` protocol (`srv/state.py`)

- `event: hello` `{epoch, versions, asset}` is always first. `asset` is the build signature (`__CANOPY_ASSET__`).
- `event: patch` `{domain, version, upserts:{type:{id: fullObject}}, deletes:{type:[id]}}`:
  - Each domain (`git`, `remote`, `review`, `todo`) has its own monotonic version. A patch's version is the
    previous one + 1, and **a gap means resync**.
  - Upserts carry the **whole** entity object, not a field diff.
  - Without `archived=1`, archiving a project shows up as deletes of its branches and PRs, and restoring
    it shows up as their upserts.
- `event: resync` `{epoch, versions}` is sent when:
  - the epoch differs (the server restarted), or
  - the client's version is older than the 128-patch ring.

  The server closes the stream after sending it. The client refetches `/state`, then reconnects.
- `event: asset` `{asset}`: the build changed (checked about every 15 s). v2 reloads when the page is quiet.
  A native client can ignore it.
- `: ping` comment about every 15 s.
- Client reconnect: exponential backoff from 500 ms up to 10 s. Hidden tabs close the stream.

### Entities *(live; keys)*

Ids:
- `repo`: `"<repo>"`
- `project`, `branch`, `pr`, `conv`, `draft`, `viewed`: `"<repo>:<name>"` (a pr/conv/draft/viewed is keyed by its head branch)
- `landed`: `"<repo>:<project>#<pr>"`
- `thread`: `"<repo>:<branch>#<threadNode>"`
- `todo`: the item slug, global

| type | domain | keys |
|---|---|---|
| repo | git | `id name main trunk`(sha) |
| project | git | `id repo name state`(focus\|workbench\|archive) `rank`(int\|null) `ticket summary size` |
| branch | git | `id repo name project parent parentId description subject commits outline`(subjects, oldest first) `tip tree pushed`(synced\|ahead\|local) `ahead gates`(green\|running\|red\|stale\|none) `redGates order holdUntil behind drifted upstream upstreamBad diverged` |
| pr | remote | `id repo branch project number url state review draft base approvals mergeState mergeable approvedAt title` |
| landed | remote | `id repo project pr title branch at` |
| warm | remote | `id`(repo) `prs`(bool: has the PR cache warmed? Until it has, a missing PR means "unknown", not "none") |
| conv | review | `id repo branch number title body url author state headRef base head tip mapping behind unpushed viewer reviews[{id author state body at url}] comments[{id author body at url}] pending unflagged at` |
| thread | review | `id repo branch pr node path line startLine originalLine originalStartLine side subject outdated resolved canResolve canUnresolve canReply comments[{id db author state body at url commit originalCommit hunk}] local fixedBy note` |
| draft | review | `id repo branch items[{key kind path side line startLine thread body err at fixFor state}]` |
| viewed | review | `id repo branch keys[]` |
| todo | todo | `id title kind state area size why blocked_by links created updated body rank waiting` |

---

## 2. Forests and projects

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `POST /project-state` [—, repo in body] | MUTATING (git config `stack-project.<p>.focus/.archived`) | `{repo, project, state: "focus"\|"workbench"\|"archive"}` | `{ok:true, project, state}` · 400 `{ok:false, error}` | `commands/project.ts` |
| `POST /focus` [—, repo in body] | MUTATING (git config focus ranks) | `{order:[{repo, project}]}` rewrites ranks 1..N. The alternative form `{repo, project, on}` is not used by v2. | `{ok:true, count}` · 400 `{ok:false, error}` | `commands/project.ts` (drag reorder) |
| `POST /integrate` [R] | MUTATING (only rebuilds the ephemeral ref `refs/stack/<p>-integration`; `checkout` and `reset` also touch a playground worktree, but v2 never sends them) | `{project}` (+ `checkout?`, `reset?`) | `{ok, project, clean, detail, playground:{path, exists, dirty, fresh}}`. `ok:false` means a bad project. Sent via `ask()`. | `integrate.ts checkIntegration` (Forests, 700 ms debounce) |
| `GET /landed-why` [R] | READ | `?pr=<n>` | *(live)* `{ok, pr, sha, subject, body}` (the squash commit on origin/main) · 404 `{ok:false, error}` | `Story.tsx` |
| `GET /packet-compare` [R] | READ (navigation) | `?branch=&base=` | **302** to the GitHub compare-and-create URL, PR body prefilled · 404 `{ok:false, err}`. Opened in the browser, never fetched. | `model.ts compareUrl` → `commands/branch.ts` (`window.open` when there is no PR) |
| `GET /preview-wait` [R] | READ (HTML page) | `?branch=` or `?project=` | An HTML interstitial that itself POSTs `/preview` or `/preview-integration`, polls `/previews` and `/preview-log`, then redirects to the dev server. Opened with `window.open`. | `commands/branch.ts`, `commands/project.ts` |

## 3. Branch: sync, gates, push

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `GET /sync` [R] | READ | `?branch=` | *(live)* `{branch, behind, parent, published, syncable, restack, project, shared, aheadOfOrigin, dirty[], dirtyRows[], dirtyWorktree, deployCritical[], why}` | `review/Ship.tsx`, `commands/sync.ts facts()` |
| `GET /prep-route` [R] | READ | `?branch=` | *(live)* `{ok, branch, route, why, next?:{method, path, body}}`. `route` is one of `dirty\|push-vehicle\|additive\|restack\|nothing\|squash\|ready` (`needsBody` may appear). | `review/Ship.tsx` |
| `POST /sync` [R] | MUTATING (fetches origin main, rebases, or launches a Claude session) | `{branch}` | One of: `{ok, restack:true, project}` · `{ok, rebased:true, summary}` · `{ok, contract:true, branch, children}` · `{ok, ejected, conflict, stream, err}`. 409 `{ok:false, err:why}` when the branch isn't syncable. | `commands/sync.ts` (`branch.sync.rebase`) |
| `POST /dirty-resolve` [R] | MUTATING (commit, stash or pop in the holding worktree) | `{branch, action: "include"\|"stash"\|"pop"}` | `{ok, out, err}` · 404 when no worktree holds the branch · 400 for an unknown action | `commands/sync.ts` |
| `POST /restack` [R] | MUTATING (background restack in a scratch worktree) | `{project}` | `{ok, project, log}` · `{ok, project, queued:true, behind, ahead}` · 409 `{ok:false, err, parked, current}` | `commands/sync.ts` |
| `POST /prep-push` [R] | MUTATING (squash, rebase, catch-up merge, reseat) | `{branch, confirm?}` | `{ok:true, routed[], outgoing, commit, wardsOk, reasons}` · `{ok:false, reconcile:true, err}` (diverged with no PR) · other `{ok:false, err, routed?}` | `commands/sync.ts` |
| `POST /reconcile` [R] | MUTATING (launches `stack-claude`) | `{branch}` | `{ok, ejected, err}` · 409 when there is no upstream | `commands/sync.ts` |
| `POST /delta-tests` [R] | MUTATING (runs tests; may materialize a scratch worktree) | `{branch}` | `{ok, ran, noTests, passed, failed, total, summary}` | `commands/sync.ts` (`alone:true`, not queued) |
| `POST /reseat-children` [R] | MUTATING (rebases child branches) | `{branch}` (the drifted child's **parent**) | `{ok, branch, results[], moved[], conflicts[], held[]}`. **207** when there are conflicts. | `commands/sync.ts` |
| `POST /fix-upstream` [R] | MUTATING (`git branch --unset-upstream`) | `{branch}` | `{ok, branch}` · `{ok:false, err}` | `commands/sync.ts` |
| `GET /diverged-detail` [R] | READ | `?branch=` | `{ok, upstream, trunk, ahead[{sha, subject, fromMain, matched}], behind[{sha, subject, matched}], containment: rebase\|contained\|clean-extra\|overlap, overlap[], prNow, prAfter, prFiles[{path, status, now, after}], forceScope}` · 404 when there is no upstream | `review/Ship.tsx` |
| `POST /gates` [R] | MUTATING (spawns the gate run; records `gates-green-tree` in git config) | `{branch, detach:true, skip?:[gate]}` (+ `force?`, `fix?`) | `{ok, cached:true, gates}` (this tree is already green) · `{ok, started:true[, already:true]}`. A non-detached call returns the full verdict, but v2 always detaches. | `commands/branch.ts` |
| `GET /gates-progress` [R] | READ, **with a side effect**: if the finished run is green, it writes `gates-green-tree` to git config | `?branch=[&gate=<name>]` | *(live)* `{running, elapsed, events[], tail?:{gate, lines[]}, result?:{ok, gates, note}, dead?}` · `{running:false, err}` | `review/Ship.tsx`, **polled every 2 s while `running`** |
| `POST /push-origin` [R] | MUTATING (`git push origin <b>`, fast-forward only; may open a browser tab unless `stay`) | `{branch, stay:true}` | `{ok, remote, web, opened, out, err}` · `{ok:false, err, verdict}` | `commands/branch.ts` |
| `GET /force-scope` [R] | READ (one GitHub call) | `?branch=` | *(live)* `{ok, forceScope:{eligible, guards[{k, label, ok}], lease, prNumber, prUrl}}` · 404 when the branch is not on origin | `commands/branch.ts` |
| `POST /force-origin` [R] | MUTATING (`push --force-with-lease`) | `{branch, lease}` (the lease from `/force-scope`) | `{ok, remote, web, opened, out, err}` · `{ok:false, err, forceScope}` (out of scope, or origin moved) | `commands/branch.ts` |
| `POST /outbox-hold` [R] | MUTATING (git config `stack-hold-until`) | `{branches:[name], until: ISO\|""}`. `""` clears the hold. The server also accepts `branch` or `project`. | `{ok, branches, until}` · 400 | `commands/branch.ts` |

## 4. Review page (diff)

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `GET /node` [R] | READ. For a `refs/stack/…-integration` branch it rebuilds that ephemeral ref. | `?branch=[&base=sha][&ws=1]`. `ws=1` keeps whitespace changes; v2 never sends it, so whitespace is hidden. | *(live)* `{branch, baseSha, worktree, dirty[], files:[{path, add, del, patch}]}`. `patch` is raw unified-diff text that the client parses (`review/diff.ts parsePatch`). Errors give 500 with `{branch, files:[]}`. | `review/page.ts` (also prefetches neighbours) |
| `GET /file` [R] | READ | `?branch=<ref or sha>&path=` | `text/plain` file contents · 404 `(file not found on this ref)` | `review/page.ts` (context expansion), `review/inline.ts` |
| `GET /commits` [R] | READ | `?branch=` | *(live)* `[{sha(short), subject, author, date, body, own, carried?, pushed?}]` (up to 80) | `review/page.ts` (history) |
| `GET /commit-diff` [R] | READ | `?sha=[&from=sha][&ws=1]` | `{sha, files:[{path, add, del, wsOnly, patch}]}` · 400 `{err}` for a bad `from` | `review/page.ts`, `review/inline.ts` |
| `POST /viewed` [R] | MUTATING (a JSON file in the git common dir) | `{branch, keys:[blockKey], on}` | `{ok, branch, count, on}` · 400 `{ok:false, error}` | `commands/review.ts viewedSet` |
| `POST /open` [R] | MUTATING (drives the warm review editor via `stack-open`) | `{branch, path, line}` (the server also accepts `pos`) | `{ok, out, err}` · 504 when the editor is wedged | `commands/review.ts` (open in Helix) |
| `POST /revert-commit` [R] | MUTATING (an unpushed commit is dropped from history; a pushed one gets a new revert commit) | `{branch, sha}` | `{ok, dropped, sha}` · 400/404/409 `{ok:false, err}` | `commands/review.ts` (`review.unapply`, history ↶) |

## 5. Review desk (ledger and GitHub)

All four routes go through `reviewdesk._guarded`: a `Refused` becomes `200 {ok:false, err}`.

| Call | R/M | Body | Response | Used by |
|---|---|---|---|---|
| `POST /review-draft` [R] | MUTATING. Writes the local ledger. Sending writes to **GitHub** (a pending review) and is gated, see Refusals. | `{branch, op:"add", item:{key, kind:"comment"\|"reply", path, side, line, startLine, thread, body, fixFor?}, send?}` · `{branch, op:"send", keys?}` · `{branch, op:"remove", key}` · `{branch, op:"edit", key, body}` (v2 never sends `edit`) | `{ok:true}`. When sending: `{ok:true, waiting}` or `{ok:false, err:"kept as a draft — …"}` | `commands/review.ts` |
| `POST /review-apply` [R] | MUTATING (a local commit applying a suggestion; never pushed) | `{branch, thread: threadNode}` | `{ok, sha}` | `commands/review.ts` |
| `POST /review-address` [R] | MUTATING (adds an `Addresses:` trailer through an outline rewrite, or launches Claude) | `{branch, thread, claude:true}` → `{ok, key}` · `{branch, thread, sha, head}` → `{ok, key, newTip}` · `{branch, undo:key}` → `{ok}` | see body column | `commands/review.ts` |
| `POST /review-note` [R] | MUTATING (launches a Claude session about one commit's line) | `{branch, sha, path, side, line, startLine, body}` | `{ok, pushed}` | `commands/review.ts` |

## 6. Words: outline and PR text

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `GET /outline` [R] | READ | `?branch=` | *(live)* `{ok, branch, parent, base, head, description, story, ticket, commits:[{sha, short, subject, body, author, date, pushed, merge, carried, locked, files, add, del}], pr:{exists, …}, draft:{title, titleSaved, body, bodySaved, derivedBody, bodyPending}, reseat, undo}` | `Commits.tsx` (**re-polled every 1.5 s while `draft.bodyPending`**), `review/Overlays.tsx` |
| `POST /outline` [R] | MUTATING. Rewrites unpushed commit messages through commit-tree plus a guarded update-ref, and writes git config for the description and PR text. | `{branch, head, edits:[{sha, subject, body}], description?, prTitle?, prBody?}`. `head` is a compare-and-swap check: the save is refused if the branch moved. | `{ok, newTip, oldTip, changed, fields[], warnings[], reseat, journal}` · `{ok:false, err, …}` | `commands/words.ts`, `commands/branch.ts` (description only: `edits:[]`) |
| `POST /outline-undo` [R] | MUTATING (replays the last outline save) | `{branch}` | `{ok, newTip, restored, commits, reseat}` | `commands/words.ts` |

## 7. Machine and previews

All machine calls are unprefixed [—], so they run against the default repo.

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `GET /previews` | READ (health-probes the dev servers) | none | *(live)* `{ok, previews:[Server], substrate:{project, dir, shared, home, starting, err, db, schema, up, total, services[], doctor:{checks, ok, broken}}}`. `Server` = `{name, port, dir, branch?, url?, state, age, health, latency?, error?, jobs?, managed?, pid?, behind?, serves?, servesMismatch?, swapTo?}` (`workstation.ts`) | `workstation.ts`, refetched on every `/events` `procs` |
| `GET /preview-log` | READ | `?dir=[&which=jobs]` | `{ok, log, path}` | `workstation.ts`, **polled every 1.5 s while a log is open** |
| `GET /footprint` | READ | none | *(live)* `{at, machine:{totalMb, pressure, levelPct, freeMb, …, swap, top[]}, repo:{worktrees, scratch, nodeModulesClones, disk, hygiene}, server:{pid, rssMb, threads, children, uptimeS, caches}}` | `workstation.ts`, **polled every 15 s** |
| `POST /preview-restart` | MUTATING (process) | `{dir, port}` | `{ok, port, url, dir}` | `commands/machine.ts` |
| `POST /preview-swap` | MUTATING (process) | `{port, branch}` or `{port, dir}` | `{ok, port, url, dir}` | `commands/machine.ts` |
| `POST /preview-kill` | MUTATING (process) | `{dir, port}` | `{ok}` | `commands/machine.ts` |
| `POST /preview-reap` | MUTATING (process) | `{}` | `{ok, out}` | `commands/machine.ts` |
| `POST /preview-main` | MUTATING (process) | `{port}` | `{ok, port, url[, dir]}` | `commands/machine.ts` |
| `POST /stack-up` | MUTATING (starts the Docker stack) | `{dir}` | `{ok, starting, dir}` | `commands/machine.ts` |

## 8. Wiki

| Call | R/M | Query | Response | Used by |
|---|---|---|---|---|
| `GET /wiki-pages` [—] | READ | `[?project=]` | *(live)* `{pages:[{slug, title, section, order, ask, lede, project, kind, body, words, dir}], ref, repo, problems[], searched[], roots[]}` · `{err}` | `wikiread.ts` (once per page load) |
| `GET /wiki-src` [—] | READ | `?anchor=` | `{path, start, end, from, text, ref}` · `{err}` (always 200) | `wikiread.ts` |

## 9. Tutor and learning

All tutor and learning calls are unprefixed [—]. The learning graph is global (`~/.dotfiles/learning`).

| Call | R/M | Body / query | Response | Used by |
|---|---|---|---|---|
| `GET /learning-state` | READ | none | *(live)* `{concepts:{id:{…, mastery, built_on_by, blocked_by}}, topics, due[], systems, standards, standards_due[], questions[], calibration[], evidence[], levels[], credits[], confidences[], rungs[], sources[], today}` | `tutoring.ts` (re-read after each turn or audit) |
| `GET /tutor-src` | READ | `?path=&ref=` | `{path, ref, text}` · `{err}` (always 200) | `tutoring.ts` |
| `GET /tutor-terminal` | READ | none | *(live)* `[{session, cwd, target, mtime, answers, last}]` (up to 8) | `tutoring.ts` |
| `GET /tutor-import` | READ | `?session=` | `{session, cwd, target, msgs}` · `{err}` (404 when there is no transcript) | `tutoring.ts pickUp` |
| `POST /tutor` | MUTATING (launches a headless `claude -p`; the turn's blocks write the learning graph). **The response is SSE.** | `{turn, tab, topic?, cwd?, target}` for a new session · `{turn, tab, answer, resume, primed?, fork?:"1", topic?, cwd?}` for an answer · `{turn, tab}` to re-attach | `text/event-stream` with events `session {session_id}`, `status {s}`, `token {t}`, `tool {name, arg}`, `graph {topic?, protocol?, errors?}`, `done {ok, session_id[, stopped]}`, `error {err}`, `gone {}`. **The server holds the connection open after `done`**, so the client stops reading when it sees `done`, `error` or `gone`. A turn id re-attaches and replays from the start (the client retries for about 60 s). 400 for no turn id or a bad cwd. | `tutoring.ts runTurn` via `streamPost` |
| `POST /tutor-stop` | MUTATING (kills the turn process) | `{turn}` | `{ok:true}` | `commands/tutor.ts` |
| `POST /learning-question` | MUTATING | `{op:"add", text, concept, topic}` · `{op:"close"\|"reopen", id}` | `{ok, id}` · 400 `{ok:false, err}` | `commands/tutor.ts` |
| `POST /learning-evidence` | MUTATING | `{op:"edit", id, fields}` · `{op:"delete", id}` | `{ok}` · 400 | `commands/tutor.ts` |

## 10. LSP (types on the diff)

All LSP calls are prefixed [R]. These are read-only POSTs sent via `ask()`, but the first request starts
`tsgo` and moves the viewer-owned type worktrees.

The position body is `{branch | sha, path, line (1-based), character (0-based UTF-16), side?: "new"|"old", base?}`.
Any of the routes below can answer `{ok:false, state:"loading"|"refused"|"error", message}`. On
`loading`, the client re-asks every 500 ms for up to 90 s; the same position re-attaches to the queued
request.

| Call | Body | Response | Used by |
|---|---|---|---|
| `POST /lsp/hover` | position | `{ok, contents(markdown), range}` | `review/types.ts` |
| `POST /lsp/definition`, `/lsp/type-definition`, `/lsp/implementation`, `/lsp/references` | position | `{ok, sha, side, locations:[{path, line, character, endLine, span?}]}` | `review/types.ts goto` (route `/lsp/${kind}`) |
| `POST /lsp/symbols` | `{branch\|sha, path, side}` | `{ok, sha, side, symbols:[{name, kind, line, endLine, depth}]}` | `review/types.ts` |
| `POST /lsp/prepare` | `{branch, base?}` | `{"ok":true}` (moves the trees in the background) | `review/page.ts` (on branch page load) |
| `GET /lsp/src` | `?path=&sha=` | `{path, sha, text}` · `{err}`. v2 fetches it with `getText` and runs `JSON.parse` itself. | `nav.ts` (picker previews) |

## 11. Todo (the viewer's feature tracker)

| Call | R/M | Body | Response | Used by |
|---|---|---|---|---|
| `POST /todo-item` [—] | MUTATING (`~/.dotfiles/canopy/todo` files) | `{id, set:{state?, rank?}}` · `{ranks:{id: n\|null}}` | `{ok, item}` / `{ok}` · 400 `{ok:false, error}` | `commands/todo.ts` |

The todo items themselves arrive through the `todo` store domain (`/state`, `/v2/events`).

## 12. Telemetry

| Call | R/M | Query | Response | Used by |
|---|---|---|---|---|
| `GET /telemetry/summary` [—] | READ | `?days=N` (default 30, maximum 3650) | *(live)* `{days, generatedAt, budgets, paintMs, commands[{app, id, budget, budgetMs, n, via, outcomes, refusedRate, failedRate, topErr, feedback, settled, over, score}], surfaces[], mostUsed[], neverUsed[], registeredAt, pairs[], weekly[], pages, ms}` | `Dashboard.tsx` |

`POST /track` is in section 1.

### Client cadence summary

| What | When |
|---|---|
| `/v2/events` | held open while visible |
| `/events` | held open while a procs subscriber exists |
| `/gates-progress` | every 2 s while running |
| `/outline` | every 1.5 s while `bodyPending` |
| `/preview-log` | every 1.5 s while a log is open |
| `/footprint` | every 15 s on the Machine page |
| `/track` | flushed every 3 s |
| LSP | re-asked every 500 ms while `loading` |
| `/integrate` | 700 ms after the Forests page settles |

---

## Appendix: server routes v2 does not call

- `GET /v2`, `/v2/*`: the SPA shell (`dist/v2/index.html`) with the injected `__VIEWER_REPOS__`,
  `__CANOPY_KEYS__` and `__CANOPY_ASSET__`.
- `GET /assets/*`: the hashed build assets.
- `GET /`, `/forests/…`, `/branch/…`, `/review/…`, `/wiki/…`, `/tutor/…` and others: 302 redirects from v1
  pages to v2 (`srv/v1redirect.py`).
- `GET /model?branch=`: v1's forest model (`stack-forest`), served stale-while-revalidate.
- `GET /sig`: `{sig, repo, pid}`, a cheap change detector; `stack-review-serve` also uses it to detect a
  foreign repo holding the port.
- `GET /packet?branch=`: the review packet (PR body as a checkable contract). *(live: `{ok, branch, tree, title, label, labelName, sections, hand, body, packetBody, …}`)*
- `GET /ext-mtime`: the Chrome extension's self-update poll.
- `GET /preview-wait` is used. The page it serves calls `POST /preview {branch}` and
  `POST /preview-integration {project}` (both MUTATING, spawn `next dev`).
- `GET /lsp/status` is documented in `srv/lsp.py`'s header but **not dispatched** (it returns 404).
- `POST /heartbeat`: `{"ok":true}`, a v1 keepalive.
- `POST /open-url`, `POST /pr-forest`: Chrome extension routes (parse a GitHub URL to an nvim or viewer
  route; get a PR's forest membership).
- `POST /diverged-additive`: drafts the additive push-vehicle branch (MUTATING, never pushes). `/prep-route`
  may name it as `next`.
- `POST /squash`: collapses `parent..branch` into one voiced commit (MUTATING).
- `POST /prep`: v1's prep-for-push (squash unpushed commits, then oxfmt) (MUTATING). `/prep-route` may name
  it as `next`.
- `POST /packet-guide`: re-drafts the packet's reading guide with headless Claude (MUTATING, process).
- `POST /chat`: a read-only Claude chat turn, streamed as SSE (used by the mail-map Q&A).
- `POST /integrate` with `checkout` or `reset`: playground worktree modes. v2 sends only `{project}`.

## Native client notes (canopy-native)

- `Transport` sends `X-Stack-Actor: browser`, `X-Request-Id: <launch>-<n>`, `User-Agent: canopy-native/0.1`, and
  `X-Stack-Via` on writes. It sends no `Origin`, so the POST origin check passes. `browser` is chosen because the
  actor enum has no native value; see PORTING.md §11.
- GitHub review writes still refuse: `ghreview.refusal()` also wants `Sec-Fetch-Site: same-origin`, which the
  native client doesn't forge. That needs a server-side allowance.
- Repos and keys come from the `<script>` the server injects into `GET /v2` (`Bootstrap.parse`). The `asset`
  value in `hello`/`asset` events moves when keys.toml is saved, and the app re-reads the bootstrap.
