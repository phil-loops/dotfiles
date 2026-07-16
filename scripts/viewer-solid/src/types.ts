// Wire shapes returned by the Python review server (stack-review-server.py + srv/*),
// expressed as zod schemas so the data contract is validated at the fetch boundary
// (see provider.ts). Types are inferred from the schemas — ONE source of truth, so a
// schema change can't drift from its type. The static-deploy bake step (a future
// StaticProvider) validates baked blobs against these same schemas, strictly.
//
// Objects strip unknown keys by default, so the server emitting extra fields (e.g.
// /projects also carries mergeable/ready/candidates) is fine — we keep what we read.
import { z } from "zod";

export const FileDiff = z.object({
  path: z.string(),
  status: z.string(), // "clean" | "stale" | "unblessed" (stack-forest file_status)
  add: z.number().optional(),
  del: z.number().optional(),
  patch: z.string().optional(),
  stale: z.string().optional(), // stale files only: the blessed-blob → current delta (what's unreviewed)
});
export type FileDiff = z.infer<typeof FileDiff>;

export const NodeMeta = z.object({
  parent: z.string().optional(),
  children: z.array(z.string()).optional(),
  requires: z.array(z.string()).optional(),
  // one-line branch purpose (git branch.<name>.description), grafted on by /model.
  description: z.string().optional(),
  // deterministic merge-order depth (stack-merge-rank), grafted on by /model. Canonical
  // order = stable sort by mergeRank asc. Shared authority with stack-pr-body — see _enrich.
  mergeRank: z.number().optional(),
  stale: z.number(),
  total: z.number(),
  clean: z.number(),
  // WAVE 1 carries each file's path + status (no patch); the map uses the paths to
  // test dirty-overlap dams. `dirty` = tracked, uncommitted paths in the branch's worktree.
  files: z.array(FileDiff).optional(),
  dirty: z.array(z.string()).optional(),
});
export type NodeMeta = z.infer<typeof NodeMeta>;

export const ForestModel = z.object({
  nodes: z.record(z.string(), NodeMeta).optional(),
  roots: z.array(z.string()).optional(),
  links: z.array(z.object({ branch: z.string() })).optional(),
  // canonical merge order (stack-merge-rank), tie-break already baked in — render verbatim,
  // do NOT re-sort by NodeMeta.mergeRank (that loses the declared-order tie-break). See _enrich.
  mergeOrder: z.array(z.string()).optional(),
  // Phil's manual promote/demote level (stack-project.<name>.interest), grafted on by /model.
  interest: z.number().optional(),
});
export type ForestModel = z.infer<typeof ForestModel>;

// A flattened forest node: its server metadata plus the row's identity + indent depth.
// Frontend-derived (flattenForest), not a wire shape — hence a plain type, not a schema.
export type SpineNode = NodeMeta & { id: string; depth: number };

export const NodeData = z.object({
  branch: z.string(),
  files: z.array(FileDiff),
  // working-tree dirt of the worktree holding this branch — read-only, unblessable
  // (blessing keys on committed content); dirt is per-worktree, it ambushes whatever
  // branch the checkout holds
  dirty: z.array(z.object({ path: z.string(), code: z.string(), patch: z.string() })).optional(),
  worktree: z.string().optional(),
});
export type NodeData = z.infer<typeof NodeData>;

export const PR = z.object({
  num: z.number(),
  title: z.string(),
  url: z.string(),
  project: z.string(),
  branch: z.string(),
  draft: z.boolean().optional(),
  review: z.string().nullable().optional(), // "APPROVED" | "CHANGES_REQUESTED" | null
  ci: z.string().optional(), // rolled-up checks: "passing" | "failing" | "pending" | "none"
  mergeable: z.string().optional(), // "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
  mergeState: z.string().optional(), // "CLEAN" | "BLOCKED" | "BEHIND" | "DIRTY" | "UNKNOWN" (often UNKNOWN from list API)
});
export type PR = z.infer<typeof PR>;

// The /prs map (stack-prs): every open PR keyed by its HEAD branch, so the forest map can
// badge a node the moment its branch has a PR. `toMain` is true iff the PR targets main (the
// forest aim — every PR merges into main); a non-main base is the stacked-PR anti-pattern.
export const BranchPR = z.object({
  num: z.number(),
  url: z.string(),
  draft: z.boolean().optional(),
  base: z.string().optional(),
  toMain: z.boolean().optional(),
  review: z.string().optional(), // reviewDecision: "APPROVED" | "CHANGES_REQUESTED" | "REVIEW_REQUIRED" | ""
});
export type BranchPR = z.infer<typeof BranchPR>;
export const BranchPRMap = z.record(z.string(), BranchPR);

export const Project = z.object({
  name: z.string(),
  repo: z.string().default("loops"), // which registry repo this forest lives in (Forests home groups by it)
  epic: z.string().nullable().optional(), // stack-project.<name>.epic — cross-repo grouping id (advisory, never a rebase base)
  branches: z.number(),
  behind: z.number(),
  mergeable: z.array(z.string()).optional(), // topo-mergeable roots; [0] is the entry node a non-loops card opens
  candidates: z.array(z.string()).optional(),
  merged: z
    .object({ pr: z.number(), title: z.string(), at: z.string(), branch: z.string() })
    .nullable()
    .optional(), // most recent squash-merge into main attributed to this forest
  landed: z
    .array(z.object({ pr: z.number(), title: z.string(), at: z.string(), branch: z.string() }))
    .optional(), // merge history for this forest, newest first (merged = landed[0])
  shipped: z
    .object({
      count: z.number(),
      latest: z.string().nullable().optional(),
      prs: z
        .array(z.object({ pr: z.number(), title: z.string().nullable().optional(), at: z.string().nullable().optional() }))
        .optional(),
    })
    .nullable()
    .optional(), // merged PRs attributed to this forest in the past month (gh-backed, not the daemon journal)
  lastCommit: z.number().nullable().optional(), // newest committer-date (unix secs) across member branches
  prOpened: z.string().nullable().optional(), // newest open-PR createdAt (ISO) across member branches
  interest: z.number().optional(), // promote/demote level (stack-project.<name>.interest) → orders this forest on Home
  shelved: z.boolean().optional(), // deliberately paused (stack-project.<name>.shelved) — out of the active bands until unshelved
  focus: z.number().nullable().optional(), // 1-based focus-lane rank (stack-project.<name>.focus); null/absent = not pinned
  tier: z.enum(["committed", "trying", "spike"]).nullable().optional(), // conviction (stack-project.<name>.tier); null/absent = untriaged
});
export type Project = z.infer<typeof Project>;

// one (branch, forest) pair — the Cmd+K global jump index across all projects/repos
export const ForestBranch = z.object({ branch: z.string(), project: z.string(), repo: z.string().default("loops") });
export type ForestBranch = z.infer<typeof ForestBranch>;

export const ReviewRequest = z.object({
  number: z.number(),
  title: z.string(),
  author: z.string(),
  url: z.string(),
  imported: z.boolean(), // a review/pr-<N> branch already fetched into the local forest
});
export type ReviewRequest = z.infer<typeof ReviewRequest>;

export const ReviewRemote = z.object({
  available: z.boolean(), // the PR's remote head differs from the local review branch (they pushed)
  remote: z.string().optional(),
  local: z.string().optional(),
});
export type ReviewRemote = z.infer<typeof ReviewRemote>;

export const Standalone = z.object({
  branch: z.string(),
  commits: z.number(),
  add: z.number(),
  del: z.number(),
});
export type Standalone = z.infer<typeof Standalone>;

export const Purpose = z.object({
  thesis: z.string(),
  enables: z.string().optional(),
  source: z.string().optional(),
});
export type Purpose = z.infer<typeof Purpose>;

export const Commit = z.object({
  sha: z.string(),
  subject: z.string(),
  author: z.string(),
  date: z.string(),
  own: z.boolean().optional(), // true = on this branch (parent..branch); false = inherited ancestor
});
export type Commit = z.infer<typeof Commit>;

export const CommitDiff = z.object({
  sha: z.string(),
  files: z.array(FileDiff),
});
export type CommitDiff = z.infer<typeof CommitDiff>;

export const RestackDriver = z.object({
  pid: z.number(),
  mode: z.string(), // start | handoff | continue | diagnose | discard | all
  project: z.string().optional(),
  etime: z.string().optional(), // ps elapsed time, e.g. "11:13"
});
export type RestackDriver = z.infer<typeof RestackDriver>;

export const RestackStatus = z.object({
  running: z.boolean(),
  paused: z.boolean().optional(),
  project: z.string().optional(),
  current: z.string().optional(),
  reason: z.string().optional(),
  done: z.number().optional(), // branches rebased so far this walk
  total: z.number().optional(), // total in the walk → "node done of total"
  completed: z.array(z.string()).optional(), // branches rebased this run (forest-map kiln: "set")
  pending: z.array(z.string()).optional(), // branches not yet reached (kiln: dim)
  // The list, not a boolean — a boolean can't tell one driver from two. >1 == a tangle.
  drivers: z.array(RestackDriver).optional(),
  resolvers: z.number().optional(), // live headless claude conflict-resolvers
});
export type RestackStatus = z.infer<typeof RestackStatus>;

// The ambient daemon's latest DRY-RUN report (scripts/restack-daemon). available=false
// means the daemon hasn't run in this repo yet. The summary counts drive the status chip;
// branches[] carries each verdict for the per-node detail.
export const RestackAmbientBranch = z.object({
  branch: z.string(),
  parent: z.string(),
  behind: z.number().nullable(),
  verdict: z.string(), // clean | would-restack | would-contract | will-conflict | skip-* | error
  would_do: z.string(),
  conflict_pr: z.number().nullable().optional(), // will-conflict: the merged PR it collides with
  conflict_title: z.string().nullable().optional(),
});
export const RestackAmbient = z.object({
  available: z.boolean(),
  tier: z.string().optional(), // the daemon's action tier: dry-run | contract | apply (scripts/restack-daemon)
  at: z.number().optional(),
  age_s: z.number().nullable().optional(),
  trunk_tip: z.string().optional(),
  report: z.object({
    branches: z.array(RestackAmbientBranch),
    summary: z.object({
      clean: z.number(), would_restack: z.number(), would_contract: z.number(),
      will_conflict: z.number(), skipped: z.number(),
    }),
  }).optional(),
});
export type RestackAmbient = z.infer<typeof RestackAmbient>;

// restack-daemon's merge attribution: when the trunk tip moves, which PRs the new
// commits came from and whether any are the user's own (drives the "just landed" chip).
export const RestackMerges = z.object({
  available: z.boolean(),
  at: z.number().optional(),
  age_s: z.number().nullable().optional(),
  from: z.string().optional(),
  to: z.string().optional(),
  direct: z.number().optional(),
  prs: z
    .array(
      z.object({
        number: z.number(),
        title: z.string().nullable(),
        branch: z.string().nullable(),
        author: z.string().nullable(),
        mergedAt: z.string().nullable(),
        mine: z.boolean().nullable(),
      })
    )
    .optional(),
});
export type RestackMerges = z.infer<typeof RestackMerges>;

export const SyncState = z.object({
  behind: z.number(), // commits on origin/main not yet in this branch
  syncable: z.boolean(), // safe to fast-forward-rebase (else stacked/published)
  restack: z.boolean().optional(), // stacked chain behind main — sync delegates to POST /restack
  project: z.string().optional(), // the project a restack delegation hands to the restack machine
  why: z.string(), // when not syncable, the reason
  deployCritical: z.array(z.string()).optional(), // deploy-critical files origin/main changed that this branch lacks
  shared: z.enum(["local", "ahead", "synced", "gone"]).optional(), // local-vs-origin: can the team see this branch?
  aheadOfOrigin: z.number().optional(), // commits origin's copy lacks (shared === "ahead")
  dirty: z.array(z.string()).optional(), // uncommitted paths (incl. untracked) in the worktree HOLDING this branch
  dirtyWorktree: z.string().optional(),
});
export type SyncState = z.infer<typeof SyncState>;

export const Head = z.object({
  branch: z.string().optional(),
});
export type Head = z.infer<typeof Head>;

// Frontend-constructed (from a parked RestackStatus) — not a wire shape.
export interface Parked {
  project: string;
  current: string;
  reason: string;
}
