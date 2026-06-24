# Spec: ghost node renders the cumulative project diff

**Status:** proposed (2026-06-24). Small viewer-lane change; the plumbing already exists.

## Why
Today the `✦ <project>` ghost culmination node only carries the **integrate-preview
badge** (clean/dirty: does the octopus land?). To actually *see* "all changes on this
project" (a branch + all its `parent`/`requires` deps) you must hand-pick the tip node and
flip `DIFF VS → main`. For a **fan-out** project (several leaves) there's no single node
that shows the union at all.

The integration ref already exists: `stack-integrate` / `POST /integrate {project}` builds
`refs/stack/<project>-integration` — an ephemeral octopus-merge of all the project's leaves
on top of `main` ("what main looks like when the whole project ships"). So the union diff
is one ref away — just render it.

## Change
Make the ghost `✦ <project>` node **selectable as a diff node**:
- base = `main`, tip = `refs/stack/<project>-integration`
- i.e. its file diff / file list / search operate over `main…refs/stack/<project>-integration`
  exactly like a real node's `parent…branch`.

Then "find `peek(` across the whole project" works for free (it spans `cache/peek`,
`metric-cells`, … not just the layer you're parked on).

## Reuse, don't add plumbing
- The integration ref is already built for the preview badge. **Hook the ghost's diff to
  the same build** (build/refresh on select; the badge action already triggers it).
- Server: the per-node diff route currently maps `nodeId → (parent, branch)`. Add: when
  `nodeId` is the ghost sentinel `✦ <project>`, map to `(main, refs/stack/<project>-integration)`.
  Everything downstream (file list, hunks, search, `o`→nvim) is unchanged.

## Decisions / edges
- **Single-tip (linear) projects:** integration ref == the tip, so `main…integration` ==
  the tip's `DIFF VS main`. No new value, and today no ghost is drawn for single-tip — keep
  that. The win is purely for **fan-out** projects. (Don't draw a ghost just to duplicate the
  tip.)
- **Freshness:** branches move, so the ref goes stale. Rebuild on select (or show
  "stale — rebuild") — reuse the badge's rebuild trigger so there's one code path.
- **Octopus has merge commits:** fine. `main…ref` is a tree diff; merge commits don't
  affect it. The integration ref is explicitly ephemeral under `refs/stack/`, never a
  branch base, so the "no merge commits" forest rule doesn't apply to it.
- **Read-only:** the ghost diff is for review/search/nvim-jump only. **Do NOT wire bless**
  on it — blessing keys on real-branch file contributions (patch-id sidecar), and the ghost
  isn't a branch. Diff + search + `o` only.
- **Static/baked provider:** integrate-preview is already gated to live mode ("static
  snapshot: no live integrate-preview"). Gate the ghost diff the same way (live-only),
  unless the bake is extended to include the integration tree. Keep them consistent.

## Pointers (verified 2026-06-24)
- `scripts/viewer-solid/src/ForestMap.tsx` — ghost node definition + the integrate-preview
  action (`ghostProject()`, `POST /integrate`, ~lines 46–65); ghost is keyed `✦ <project>`,
  ranked by longest path from main over parent+requires edges.
- `scripts/viewer-solid/src/App.tsx` — node-select → diff-view wiring (the `DIFF VS` base
  toggle lives here; add the ghost's (main, integration-ref) base case).
- `scripts/srv/` — the diff route that computes `parent…node` (point it at the integration
  ref for the ghost), and the `POST /integrate` handler that already builds the ref.
- `scripts/stack-integrate` — builds `refs/stack/<project>-integration` (octopus of leaves
  on main). Reuse as-is.

## Net
~last-10% wiring: the ref is built, the ghost exists, the diff machinery exists. The change
is "let the ghost be a diff node whose base/tip is (main, integration-ref)" — and a fan-out
project gets a searchable "all changes on this project" view for free.
