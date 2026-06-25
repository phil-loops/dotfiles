# Mobile "Prepare to Push" — design

## One-liner

A phone-sized screen, served off the local forest viewer through a Cloudflare
Tunnel behind Access, that turns a messy local branch into a single clean
pushable commit: squash unpushed work → haiku-drafted subject in house style →
run the gates → push if green. Commit-crafting is the rare git task that is
*better* on a phone — judgment-dense, input-light — so this is the slice of the
workflow worth taking on the go.

## Why this is the right slice for mobile

- The hard, miserable-on-mobile parts (writing code, resolving real conflicts)
  you would never do on a train anyway.
- What's left — read a diff, decide squash boundaries, pick a message, push —
  is all decisions and almost no typing. That fits a thumb.
- The execution always happens on the Mac (the phone is a dumb remote over the
  tunnel), so there's no "can my phone run tsgo" problem. The phone only renders
  state and sends intents.

## The flow (happy path)

1. **Pick a branch** — from the existing forest list / Cmd+K jump, but a
   mobile-first card view: one branch, its `parent...branch` summary, its commit
   list, and a single primary button: **Prepare to push**.
2. **Squash everything not on origin** — fold `origin/<branch>..HEAD` into one
   commit. If the branch was never pushed, that's the whole branch from its
   parent → one clean commit (the common case). If it has pushed commits, only
   the unpushed delta is squashed on top. *This boundary is the whole safety
   story — see below.*
3. **Haiku drafts the subject** — given the squashed diff, propose 2–3 commit
   subjects in Phil's house style. Tap one or tweak it inline.
4. **Run the gates** — pre-commit hooks (lint / tsgo / etc.) on the final
   squashed tree, then the WIP-ban check. Green → ready. Red → **blocked**
   state (see constraint below).
5. **Push** — Phil taps the actual push himself. Always a fast-forward, never
   `--force`.

## The three hard requirements (Phil's words)

### 1. Squash everything that isn't on origin

Scope the squash to **unpushed commits only** (`origin/<branch>..HEAD`, or
`<parent>..HEAD` when the branch has no upstream yet). This is deliberately *not*
"squash to exactly one commit" — that would sometimes require rewriting
already-pushed history.

Consequences, all good:

- The result is always a **fast-forward push** — no `--force`, no clobbering a
  branch another session is live on. Lines up with the standing rule: never
  rewrite pushed history, never force-push a maybe-shared branch.
- New branch → "not on origin" is everything → you get the single clean commit
  you wanted.
- Branch with pushed commits + local WIP → squashes just the WIP delta on top,
  leaving pushed commits untouched.

If a branch genuinely needs to collapse *pushed* commits too, that's a
force-push and explicitly out of scope for the mobile flow — do it on the laptop
with eyes on it.

### 2. Ban our own WIP commits from ever being pushed — two layers

The UI gate is UX, not a guarantee. Enforcement is a git hook.

- **Marker on the way in.** When Claude makes a throwaway/checkpoint commit,
  stamp it unmistakably. Prefer a git trailer (`X-WIP: true`) over a bare `WIP:`
  subject prefix — it survives interactive history, is trivially greppable, and
  doesn't fight the conventional-commit subject format. (A subject prefix is the
  fallback if trailers are annoying to thread through.)
- **Enforcement at the door.** A `pre-push` hook aborts the push if *any* commit
  in the push range carries the marker. This is the real guarantee: it catches
  the case where you push from the laptop and forgot the prep flow entirely.

Defense in depth: in the happy path the squash step *consumes* the WIP commits
(they get folded into the one clean commit with the haiku subject), so there's
nothing left to ban. The pre-push hook is the net for when the flow is skipped.

### 3. Run the pre-commit hooks

Run them on the **final squashed state**, once — not per-commit. Order:

```
squash unpushed → haiku subject → pre-commit hooks → pre-push WIP check → push
```

**Honest constraint:** if `tsgo`/lint fails, you cannot fix code from a phone.
So hook failure is not "tweak and retry" — it's a clean **blocked** state:
"needs the laptop." The mobile flow's job is "prep and push the green ones," not
"rescue the red ones." That's a feature, not a gap — it keeps the scope sane.

## The rules gate (the "no junk reaches origin" contract)

Before the push button enables, the branch must pass a visible checklist. Each
failure is a red badge with (where possible) a one-tap fix:

- No `X-WIP` / WIP commits in the push range → fix: re-run squash.
- Conventional prefix present on the subject (`chore:`/`feat:`/`fix:`/…) → fix:
  haiku re-draft.
- Branch description set (`git config branch.<name>.description`) → fix: haiku
  suggest.
- Pre-commit hooks green → no auto-fix; blocked if red.
- (Optional) Linear ref present if the branch name carries an `LOO-####`.

Doing this in the push UI (vs. a silent pre-commit hook) is the point: it's the
*last* gate and it's *visual* — you see "3 WIP commits" and the fix is one tap.

## Haiku for the subject

- Cheap, fast, perfect-for-haiku: it already has the diff, it just drafts.
- **Pin the style by exemplar, not prose.** Feed haiku ~20 of Phil's recent real
  commit subjects (`git log --format=%s -20`) as the style sample rather than
  describing "terse, lowercase, chore:-prefixed, ticket-tagged." Mimicry beats
  instruction.
- Reuses the viewer's existing haiku-suggest plumbing (today pointed at branch
  descriptions) — same seam, aimed at the commit subject.

## Security — this is the write path, so Access is non-negotiable

Squash + push from a public URL is exactly what you do not want
unauthenticated.

- **Named Cloudflare Tunnel + Cloudflare Access (Zero Trust)**, locked to Phil's
  Google identity. Not a throwaway `--url` quick tunnel (zero auth).
- The mutating endpoints (`/checkout`, `/squash`, `/restack`, and the new
  prepare/push ones) must be unreachable without passing Access.
- `caffeinate` while tunneling so the Mac doesn't sleep mid-session.
- The pre-push hook is also a security backstop, not just a style gate.

## Architecture / where it lives

- **Frontend:** a mobile-first route in `scripts/viewer-solid/` — a single
  branch card, not the full forest graph. Reuse branch list + Cmd+K jump.
- **Backend:** new endpoints in `scripts/srv/` (sibling to `chat.py`,
  `sync.py`):
  - `POST /prepare` — squash unpushed, run gates, return state (clean / blocked
    + reasons). Idempotent-ish; safe to re-run.
  - `POST /commit-subjects` — haiku drafts N subjects from the squashed diff +
    style exemplars.
  - `POST /push` — fast-forward push only; refuses if not FF or if WIP marker
    present (belt with the hook's suspenders).
- **Hooks:** a repo `pre-push` hook that greps the push range for the WIP
  marker and aborts. Lives in the loops repo (or global hooks path), not the
  viewer.
- **WIP marker:** wherever Claude makes checkpoint commits, add the `X-WIP: true`
  trailer.

## v1 — smallest thing that proves the whole idea

One branch card + one **Prepare to push** button that:

1. squashes `origin/<branch>..HEAD` (or `<parent>..HEAD`) into one commit,
2. haiku-drafts the subject (tap to accept/edit),
3. runs the gates and shows clean / blocked,
4. leaves the actual `push` tap to Phil.

Plus the `pre-push` WIP-ban hook (independently valuable — protects every push,
mobile or not).

Explicitly **not** in v1: conflict resolution, force-push/pushed-history
collapse, multi-branch batch prep, editing code.

## Open questions

- WIP marker: trailer (`X-WIP: true`) vs subject prefix — confirm which threads
  most cleanly through Claude's existing commit-making.
- Does `/prepare`'s squash run in an isolated worktree (like `/sync` does) or on
  the branch in place? In-place is simpler but races the main checkout if Phil's
  there; isolated worktree is safer and matches the rebase-forward fast path.
- Pre-commit hook runtime on mobile — show streamed progress (SSE, like the chat
  drawer) or just a spinner + final verdict?
- Should `/prepare` set the branch description via haiku too if it's missing, or
  only flag it?
