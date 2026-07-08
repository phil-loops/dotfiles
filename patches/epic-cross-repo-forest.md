# Cross-repo forest grouping ("epic")

Goal: one effort split across repos (e.g. the ClickHouse monitor fix — alert in
loops, agent scrape in monotoad) shows as ONE grouped card on the Forests home,
instead of two look-alike cards under different repo headers.

Git can't express a cross-repo `parent`/`requires` (a monotoad branch can't be a
loops branch's rebase base), so the link is metadata only — advisory, never a
rebase base. Restack stays per-repo; each branch rebases on its own main.

## Config convention (ALREADY SET, lane-safe, in the product repos)

    git config stack-project.<name>.epic <epic-id>

Set today on both halves of the monitor fix:
- loops    `stack-project.ch-monitor.epic       = ch-monitor`
- monotoad `stack-project.ch-monitor-scrape.epic = ch-monitor`

## 1. Backend — DONE, see `epic-field-picker.patch` (applies clean to HEAD)

`srv/picker.py` `_projects_for`: emits `p["epic"]` (str | None) per project — one
`git config` read. Purely additive; the flat `/projects` response shape is
unchanged, so nothing breaks if the frontend ignores it.

## 2. Frontend — viewer lane, NOT yet done (this is the visible part)

- `src/types.ts`: add `epic?: string` to `Project`.
- `src/App.tsx` `forestGroups()` (~line 670): today it buckets by `p.repo`. Add a
  pass that pulls every project with a non-null `epic` OUT of its repo bucket and
  into a synthetic "epic cluster" rendered as one card — two repo-badged
  sub-rows (loops row, monotoad row), each still linking to its own per-repo
  forest via the existing repo-aware routing (`/<repo>/` prefix already works, so
  clicking a sub-row lands in the right repo — no checkout/bless change needed).
- Placement: rank the cluster by its members' max interest so both halves sit
  together at the top regardless of repo.

## 3. Later (out of scope for the grouping prototype)

- Advisory cross-repo edge: `stack-branch.<b>.requires-ext <repo>:<branch>`,
  rendered dashed, drives the ship-order verdict ("apply monotoad scrape before
  loops monitor"). Metadata only.
- Merged bless view: blessing ledger + `model_sig` cache are per-repo (keyed off
  each repo's git-common-dir). A single unified forest DIFF view would need to
  read both ledgers and invalidate on either repo's change. The grouping card in
  step 2 sidesteps this by linking to two existing per-repo forests rather than
  fusing them.

Reason this is a handoff: the viewer lane (`scripts/srv/`, `scripts/viewer-solid/`)
is held live by another session; step 1's patch is protocol-authored so it can
land via `git apply --3way` when the lane is quiet, or be taken by the owner.
