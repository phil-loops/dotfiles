# Viewer Flow & Blessing — redesign plan

Source: Phil's 2026-06-25 walkthrough of the :62497 blessing viewer. The overarching
complaint is **the site flow doesn't feel natural** — and the blessing core (the whole
tool's thesis) is under-tested while carrying a lot of config. Plumbing should recede;
review + authoring should stay; gold stays earned, and the thing that earns it must be
trustworthy.

## Status (2026-06-25 session)

**Shipped + committed (isolated work — all off the contested App.tsx):**
- MobilePush one-tap redesign — `9a87cb3`
- Blessing core VALIDATED + regression test `scripts/test-stack-bless.sh` — `c081b5f`
- `base=blessed` since-blessed diff fix (T7 bug) — `a83afb4`
- `gh-review-notify` (poll /notifications → ntfy) + launchd agent — `dea8bdd`, `925b0ca`
- `restack-dryrun` (ambient-restack dry-run-first prototype) — `f17c45e`

**Unblocked + landed (2026-06-26 morning — the viewer session exited overnight; recovered its
orphaned WIP into clean commits, then landed UI on top):**
- Recovered dead session's WIP as its own commits: reconcile-diverged front+back
  (`8e72d96`/`c1e3d7b`), readable-diff CSS (`e131cec`), diff-tuner (`b70f26c`).
- Map removal — committed clean (`c4c9d8f`).
- **Forests lists ALL forests + PR badges** (`31f2ccf`) — the IA fix.
- **Collapsible files**, blessed-no-delta collapsed by default (`3b4d312`).
- **Collapsible side panel** for full-width diff (`4748c10`).
- **Cut the Watching tab + page** (`e5a2a08`) — standalone query + promote/checkout helpers
  retained (review-import still uses standalone; promote/checkout are salvage candidates).
- **Back-to-flowchart highlights the node you came from** (`49ad58f`) — `⊞ project` action +
  module-scope `cameFrom` (effect-tracked) passed as the overview map's active node.

- **Purpose hover popovers** (`e54adb1`) — hovering a Forests row pops a card of its branches
  + one-line purposes (`/forest-purposes?project=X`, cached, short delay). Aggregation solved.

- **Header light declutter** (`8768be6`) — `↓ N behind` folded into the restack button,
  `tidy commits` moved into the ⋯ menu; push-blocked stays the one alarm. The full ambient
  model (below) is the deeper version.

**Delightful-UI backlog: CLEAR.** Everything from Phil's walkthrough is shipped.

**Remaining (bigger / optional, not part of the delight pass):**
- **Full ambient-restack daemon** (Phase 3) — the real header endgame: forests auto-restack,
  the header collapses to one status chip. `restack-dryrun` (`f17c45e`) is the dry-run-first
  foundation. A standalone project when wanted; stage carefully (dry-run-first).
- Small follow-ups: dead-code sweep of the now-unused watching helpers; wire salvaged
  promote/checkout onto a branch-row context; group the forest-level restack with the
  branch one (cross-component).
- GitHub notify → Work-page live-refresh (the `gh-review-notify` loop as a second consumer).

**Local-delta composer** — backend ALREADY EXISTS in `stack-squash` (`--unpushed`/`--unstage`);
it's an App.tsx UI over that, not a new CLI. Don't rebuild the engine.

## North star

- **Trust before polish.** Blessing is the conceptual center. Validate/simplify it before
  building more gold UI on top.
- **Plumbing recedes.** Restacking becomes ambient (loud only on real conflict); the node
  header stops being a 10-button control panel.
- **The map is a destination, not chrome.** Never docked into the review surface; you pop
  out to it and it remembers where you were.
- **One natural spine.** Cut the dead tab, stop hiding forests, make purpose legible on hover.

---

## Phase 0 — Trust the core (foundational, gates the rest)

**Blessing audit — DONE (subagent A).** Findings (cited locations in the audit):
- **R1 (HIGH, real bug):** the `base="blessed"` ("DIFF VS last blessed") pill passes the
  non-ref string `"blessed"` into `git diff`; `git_out` swallows the error → empty diff, no
  rows. Half-wired. `App.tsx:996` → `stack-forest:289`. **Fix or delete the pill.**
- **R2 (HIGH, unproven core):** bless keyed on `git patch-id --stable` of `-U0
  parent...branch`. Rebase-stability is conditionally false — a rebase that re-touches the
  hunk (overlapping upstream change / conflict resolution) shifts the id → false stale; and
  byte-identical hunks with different content → false clean (R3). No test covers a real
  `rebase --onto`. `contrib_id` at `stack-forest:32`, dup'd in `stack-bless:84` /
  `stack-blessed-status:51`.
- **Sprawl:** two ledgers (`stack-blessed.json` blob + `stack-blessed-contrib.json`
  patch-id), three divergent classifier copies (`stack-forest:256`,
  `stack-blessed-status:49`, `App.tsx:65` — whose `"blessed"` arm is dead, backend never
  emits it), cache key stamps blob sidecar but not contrib (R5), rename entries leak (R6),
  no locking (R8). **Zero automated coverage today.**

**Decision gate — RESOLVED (subagent C, `scripts/test-stack-bless.sh`, untracked).** The
rebase-survival harness ran T1/T2/T3 + the T7 repro against throwaway repos. Result:
- **T1 (clean parent move): PASS** — stays blessed, contrib key drove it.
- **T2 (the decider — rebase re-touches adjacent lines, real conflict resolved keeping the
  branch's change): patch-id BYTE-IDENTICAL before/after** → reads **clean, not falsely
  stale**. The blob key would go *falsely stale* here (file now also carries the upstream
  line). So patch-id is not just sound — it's **strictly better** than blob for the case
  that matters.
- **T3 (stale→re-bless): PASS.** Classifier parity held (stack-forest ≡ stack-blessed-status).
- **T7: bug CONFIRMED** — `--base blessed` passes a non-ref into `git diff`, error
  swallowed, 0 rows.

**Verdict: KEEP the contrib (patch-id) ledger.** R2 fear was wrong — the core is trustworthy.
So Phase 0 is NOT a rewrite and there is **no bless migration risk.** Bounded cleanup only:
- **Fix/remove the `base=blessed` pill (R1/T7)** — repoint at the per-file `stale` diff or
  delete it.
- **Dedupe the classifier (R4)** — one `file_status`, delete the dead `"blessed"` arm in
  `App.tsx:65`.
- **Stamp `stack-blessed-contrib.json` in `model_sig` (R5)** so a contrib-only write can't
  serve a stale spine.
- Keep the blob ledger only as the documented legacy/nvim fallback. (R6 rename-leak, R8
  locking: note as low-priority follow-ups.)

---

## Phase 1 — IA rethink (the nav)

**IA thesis — DECIDED: "two coherent views over one dataset."** The root unnaturalness was
a forest *teleporting* — it left Forests the moment it got a PR and reappeared on Work.
Fix: the two tabs become **whole + subset of the same data**, not disjoint sets.

- **`In flight`** (was `Work`, the best page — kept) = your **active subset**: open PRs
  (grouped by forest, as today) + **review requests** + (Phase 3) conflicts/needs-you. The
  fast lane to "what needs me now."
- **`Forests`** = the **complete index**: ALL forests, **nothing hidden**, PR'd ones
  **badged** (`[PR #1234]`, draft/review state). A PR'd forest legitimately appears in both
  views — one is "everything," one is "the active subset" (All Mail vs Important). That
  legibility is the fix; the disappearance was the bug.

Concrete changes:
1. **Drop the `nonPrProjects` filter** (`App.tsx:378-379`) — Forests renders all
   `projects`, not `projects − prProjects`. Delete the "every forest has an open PR ✦"
   empty-state branch (no longer reachable).
2. **PR badge on forest rows** — a forest with an open PR shows `[PR #N]` + GitHub state;
   reuse the `prProjects`/`myPrs` data already in `Home` to look up the PR per project.
3. **Rename the `work` tab to `In flight`** (label only; keep the `work` route id so URLs /
   telemetry don't break — `HomeTab` stays `"work"`).
4. **Cut `Watching` as a top-level tab.** Salvage `promote` (loose branch → forest) +
   `checkout` onto the branch's own row where it already appears; keep the `/standalone`
   pin + `/review-import` plumbing but drop the third tab.
5. **Purpose hover popovers** on forest/PR rows — reuse the spine's `/purpose` +
   `.purpose-tip` (`App.tsx:1209-1221, 1561-1566`). No new backend.

## Phase 2 — Review surface declutter

6. **Kill the docked map** on node detail (`App.tsx:1546-1557`). Replace with a one-tap
   **"back to flowchart"** action: drop `node` from the location
   (`{forest,name,node}` → `{forest,name}`), and have the overview **stash + subtly
   emphasize the node you came from** (a `from` hint).
7. **Collapsible side panel** (the `N/M FILES BLESSED` file list) → reclaim horizontal
   diff width; re-expandable.
8. **Collapsible files.** Per-file collapse/expand on `FileEntry` (`App.tsx:1572+`). A
   **blessed file with no delta collapses by default**, re-expandable.
9. **Header de-clutter.** Collapse the ~10 controls (`hide map`, `restack forest`,
   diffs/commits, DIFF VS parent/main/last-blessed, `N behind`, `restack branch`,
   `tidy commits`, `…`, `✦`, chat) toward: the diff, a quiet auto-restack status, a
   compose/squash affordance. Restack buttons recede into Phase 3's ambient model.

## Phase 3 — Bigger bets (design-first)

10. **Ambient auto-restack + proactive origin/main awareness.** → subagent B — DONE.
    Verdict: ~80% **policy + surfacing** over existing machinery, not new plumbing. The four
    genuinely-new pieces:
    - **(a) Boot-time trunk daemon.** Promote `_freshen_trunk` (`sync.py:147-160`) to a
      standalone thread; fire an ambient restack pass **only when `origin/main`'s tip SHA
      changes** (event-driven, fires at the merge rate — never a poll loop / thrash).
    - **(b) `forest_status` cache** keyed `(model_sig, origin/main tip)` fusing the signals
      that already exist (`behind` count, file-`overlap` from `picker.py:187-198`,
      `rebase-classify` 0/20/30) into one per-branch enum:
      `clean | behind-clean | will-contract | at-risk | will-conflict | conflicted`. No
      trial rebase on the hot path.
    - **(c) Cached `--deep` probe** for the `at-risk` minority only (file-overlap branches),
      keyed `(branch tip, main tip)` → drives a **`⚠ will conflict with #<PR>`** badge,
      naming the culprit via `picker.py`'s `_scan_merges()`. Definitive (real trial rebase),
      so the badge never cries wolf; feasible because only 0–2 branches/merge overlap.
    - **(d) Header collapse:** four restack buttons → one quiet status chip
      (`✦ clean` / `⟳ restacking…` / `⚠ will conflict` / `merged — drop?`) whose **only**
      action is **resolve a real conflict**. `tidy commits`/`prep` demotes into the `⋯`
      menu (it's commit-hygiene, orthogonal to restack — demote, don't delete).
    Clean restacks are **silent** (the only observable is `behind` returning to 0). Safety:
    reuses every existing gate — `syncable` skips open-PR branches, `_direct_rebase` rebases
    only in a branch's own clean worktree (skips dirty = live session), single-flight lock,
    resilient skip-and-continue so one conflict can't wedge the others. **No new force-push
    surface.** Full spec in subagent B's report; key files `sync.py` / `restack.py` /
    `picker.py:184-208` / `rebase-classify` / `stack-restack` / `NodeActions.tsx`.
11. **Local-delta commit composer + squash-as-unit.** A small interface to write the
    **subject + body for your uncommitted local delta** (scratch, not in shared history
    yet), and **play with ideas then squash them as a unit**. Sketch:
    - Compose pane bound to the working-tree delta (`git diff` / staged), writing a
      draft message that lives outside history until you commit.
    - "Squash as a unit": select a run of local (unpushed) commits → `reset --soft` to base
      → recommit with the composed message. Reuses the unpushed-squash logic already in the
      mobile prepare-to-push (`/prep`).
    - Needs its own design pass before code.
12. **GitHub notifications (already researched).** Background poll of `GET /notifications`
    (conditional requests, honor `X-Poll-Interval`; 304s are free), filter
    `reason ∈ {review_requested, state_change}`. Two consumers off one loop: live-refresh
    the Work PR/review list (retire manual `↻ check origin`), and **phone-push via ntfy**.
    PAT-classic only (scopes `notifications`+`repo`); GitHub App tokens don't work here.

---

## Constraints / lanes (why this isn't a dozen parallel agents)

- **`App.tsx` is one giant file** — Home, Forests, NodeDetail, FileEntry all live there.
  Items 2-9 all touch it. Parallel editors would clobber each other → **UI edits serialize.**
- **Another viewer session is live** on the chat files (`ChatPanel/ChatIndex/chatStore/
  chatRunner`) and has **`index.css` dirty** → contested. Any CSS touch goes via the
  patch protocol (worktree → `.patch` → `apply --3way`).
- **ChatPanel "always dismissible"** (no state where × / Esc fails) → **owned by the other
  session**; not in this plan's edit scope.
- `MobilePush` one-tap redesign already landed (commit `9a87cb3`).

## Subagent tasking

- **A — Blessing audit** (read-only): Phase 0. Running.
- **B — Ambient restack + origin/main awareness design** (read-only): Phase 3 item 10. Running.
- UI cluster (Phases 1-2): serial, by me, lowest-risk-first, patch for contested files.
- Local-delta composer (item 11) + GitHub notify (item 12): design/implement after the
  audit lands and the IA settles.
