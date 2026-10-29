/// GET /wiki-pages, trimmed to five pages (saved from the live server 2026-10-29).
enum WikiFixture {
    static let pages = #"""
{
 "pages": [
  {
   "slug": "api-pagination",
   "title": "Pagination foundation",
   "section": "API foundation spikes",
   "order": 10,
   "ask": "lib/rest-api/pagination.ts",
   "lede": "nextPage is rebuilt from two params; the first filterable list endpoint ships broken links on day one.",
   "project": "api-pagination",
   "kind": "design",
   "body": "Every public list route returns a [`nextPage` URL](src:lib/rest-api/pagination.ts#buildPaginationMeta) materialized from exactly `cursor` and `perPage`. Any other query param — a filter, a sort — is dropped from the link, so a client following it would paginate the *unfiltered* collection.\n\n**Nobody is bitten today.** All ten list routes validate with [`listQueryValidator`](src:lib/rest-api/pagination.ts#listQueryValidator), which knows only those two params; unknown input is stripped before it reaches the DB, so `nextPage` is currently consistent with behavior. The bug is fully latent — and the metrics API is exactly the filterable list endpoint that detonates it. Nothing in types or tests would flag it.\n\n`nextPage` can't be dropped: it is a **required** property of the published `Pagination` schema (openapi.json), though every doc description steers users to `nextCursor` instead. So: fix, don't delete.\n\n**The fix** — `buildPage`/`buildPaginationMeta` take the *validated* zod output (`query.data`) instead of a bare `perPage`, and rebuild `nextPage` with `URL` + `URLSearchParams` (which also fixes the missing cursor encoding). Validated-only input means the link reflects params the route actually applied, never echoes arbitrary junk. Ten call sites change mechanically.\n\n**Forest** (chain, one concern each):\n\n1. `api-pagination/next-page-query` — rebuild nextPage from the validated query object; util + 10 call sites + tests.\n2. `api-pagination/consolidate-lists` — replace the byte-equivalent hand-rolled hasMore/slice/nextCursor blocks in `campaigns/index.ts` and `transactional-emails/index.ts` with `buildPage`; zero customer delta.\n3. `api-pagination/per-page-min` — relax the arbitrary min-10 clamp to 1, plus its duplicate in the workflow list validator and ~10 doc strings; only turns 400s into 200s.\n\n**Out of scope:** migrating those two routes to `defineRoute` (auth/validation ordering flips 400↔401), and legacy `/v1/transactional` (deprecated; its post-filter cursor has a documented dangling-cursor quirk we're leaving alone).\n\n**Merge priority (Phil, 2026-08-17):** branch 1 is the prerequisite — it's the shared util the metrics list endpoints build on, and its old-endpoint touches are byte-neutral signature mechanics. Branches 2 and 3 are pure-conformance polish, explicitly **parkable** — push them whenever, or never; nothing downstream depends on them.\n",
   "words": 319,
   "dir": "~/.dotfiles/wiki/loops"
  },
  {
   "slug": "overview",
   "title": "Six hops, end to end",
   "section": "Orientation",
   "order": 10,
   "ask": "lib/send-mail.ts",
   "lede": "What happens between sendMail() and SES, and where the mail physically sits at each step.",
   "project": "",
   "kind": "map",
   "body": "Every email in the product enters through one function — [sendMail](src:lib/send-mail.ts#sendMail) — and leaves through SES. Between those two points it is written down, parked, claimed, metered, rendered and sent, by four different processes that share no memory.\n\nThe hops:\n\n1. **[[hop-birth]]** — a *render request* row is written to Postgres, stamped with a priority.\n2. **[[hop-park]]** — its id is pushed into that team's Valkey queue. Nothing is running yet.\n3. **[[hop-claim]]** — a separate long-running service claims a whole team to work on.\n4. **[[hop-peek]]** — one atomic script decides which ids may move, and how many.\n5. **[[hop-render]]** — a worker turns ids into bytes and puts them in S3.\n6. **[[hop-send]]** — another worker calls SES and reports how long the whole trip took.\n\nThat timing report feeds back into hop 4, which is the part worth understanding: the pipeline throttles itself based on its own measured latency. See [[throttles]].\n\nThe stores are described separately, because most confusion here is about *where a thing lives*, not *what runs next*: [[enqueued-email]], [[status-log]], [[packed-artifact]], [[team-queue]], [[team-lease]], [[throttles]], [[sqs-queues]], [[partitions]].\n",
   "words": 181,
   "dir": "~/.dotfiles/wiki/loops"
  },
  {
   "slug": "hop-birth",
   "title": "1 · Birth",
   "section": "The six hops",
   "order": 30,
   "ask": "lib/send-mail.ts",
   "lede": "any web or API process — the render request is written down and stamped with a priority.",
   "project": "",
   "kind": "map",
   "body": "Five callers funnel into `sendMail`: the transactional API, a workflow's send-email node, campaign fan-out, opt-in, and previews.\n\n[getPriority](src:lib/send-mail.ts#getPriority) stamps the number that decides everything downstream — transactional 32, preview 48, workflow 64, campaign 128. Then a single Postgres transaction writes the [[enqueued-email]] row together with its first [[status-log]] entry, so a row can never exist without a state.\n\n**Priority 64 is the fault line.** \"High priority\" is defined as strictly less than [the threshold](src:lib/mail-send-tokens.ts#HIGH_PRIORITY_THRESHOLD), and [isHighPriority](src:lib/mail-send-tokens.ts#isHighPriority) is the one-line test. Workflow mail is *exactly* 64 — so it falls on the low-priority side by a single point, sharing a class with campaign mail.\n\nWithin that class its lower number still sorts it ahead of campaigns. But the consequence that matters is at [[hop-peek]]: it is subject to the token gate, and transactional mail is not.\n",
   "words": 135,
   "dir": "~/.dotfiles/wiki/loops"
  },
  {
   "slug": "hop-park",
   "title": "2 · Park",
   "section": "The six hops",
   "order": 31,
   "ask": "lib/enqueue-email.ts",
   "lede": "same process, right after the commit — the id goes into the team's queue and nothing runs.",
   "project": "",
   "kind": "map",
   "body": "[enqueueEmails](src:lib/enqueue-email.ts#enqueueEmails) pushes just the **id** (with teamId, priority, createdAt) into that team's queue, then marks the team active. See [[team-queue]] and [[team-lease]] for what those two writes land in.\n\nNothing is executing yet. The mail is parked — and that pause is the point.\n\nAn id sitting in a sorted set can still be **reordered** and **metered**. A job already handed to SQS can be neither: it delivers in roughly arrival order, with no place to say \"these five million wait, that one transactional email goes now.\" So the two levers this whole pipeline turns on only exist while the mail is a parked id — [[hop-peek]] pulls the highest-priority class first because [[team-queue]] holds the ids sorted by priority, and the [[throttles]] decide how fast they leave.\n\nPush straight to SQS and both levers vanish: a five-million-recipient campaign floods the queue, transactional mail waits behind it, and there is no single place to intervene. That is exactly what Hops 3 and 4 are — the ordering and pacing this buffer makes possible.\n",
   "words": 173,
   "dir": "~/.dotfiles/wiki/loops"
  },
  {
   "slug": "canopy-v2-sync",
   "title": "The sync contract — /state and /v2/events",
   "section": "Canopy v2",
   "order": 57,
   "ask": "",
   "lede": "The v2 store hydrates once from a snapshot, then applies entity patches the server pushes per domain. One config write is one small patch, never a refetch.",
   "project": "canopy-v2",
   "kind": "design",
   "body": "Design: [[canopy-v2-architecture]]. Code: `srv/state.py`.\n\n**`GET /state`** returns `{epoch, versions, entities}`. Entities are keyed by type, then id:\n\n- `repo`; `project` (state focus/workbench/archive, rank, ticket, summary);\n- `branch` (parent, description, own commits, tip, tree, pushed, gates for this tree, its merge-order position, its hold-for-morning stamp, and what ⟲ sync would fix from the refs alone: `behind` main, `drifted` off its parent, a footgun `upstream`, a `diverged` pushed copy — dirt and the prep route are read per branch on its page);\n- `pr` (number, url, state, review, base, approvals, merge state — what an approved PR waits on), from the caches only, never gh;\n- `landed`, the merge ledger's shipped steps.\n\nIds are `<repo>:<name>`. Archived projects are listed, but their branches and PRs only come with `?archived=1`.\n\n**`GET /v2/events`** (SSE), connected with the versions the snapshot returned:\n\n- `hello {epoch, versions}` on connect;\n- `patch {domain, version, upserts, deletes}` whenever a domain changes;\n- `resync` when the client can't be caught up: refetch `/state`, then reconnect.\n\n**Two domains, each with its own version:**\n\n- `git` covers repos, projects and branches. It rebuilds only when the stat-gated repo fingerprint or a gate job moves.\n- `remote` covers PRs and landed steps. It's rebuilt from memory every tick.\n\nThe server diffs each rebuild against the last one and keeps the last 128 patches. Every version is the previous one plus one, so the client treats a gap as a resync. A POST wakes the refresher, so its patch follows the response within milliseconds.\n\n**Measured on the live repo (2026-10-22, read-only harness):** warm `/state` 2 ms (p95 3); after a config write 25 ms; after a ref move 100 ms. The snapshot is 103 KB (265 KB with the archive).\n",
   "words": 286,
   "dir": "~/.dotfiles/wiki/loops"
  }
 ],
 "ref": "origin/main",
 "repo": "loops",
 "problems": [
  "canopy-v2-branch-extras: no frontmatter"
 ],
 "searched": [
  "~/.dotfiles/wiki/loops"
 ],
 "roots": [
  "~/.dotfiles/wiki/loops"
 ]
}
"""#

    /// GET /wiki-src?anchor=lib/send-mail.ts#sendMail, trimmed.
    static let src = #"{"path": "lib/send-mail.ts", "start": 38, "end": 40, "from": 35, "text": "  }\n}\n\nexport async function sendMail(\n  args: SendMailArgs,\n  deps: SendMailDeps = defaultSendMailDeps", "kind": "symbol", "ref": "origin/main"}"#
}
