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
  status: z.string(), // "clean" | "blessed" | "added" | "modified" | …
  add: z.number().optional(),
  del: z.number().optional(),
  patch: z.string().optional(),
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
});
export type ForestModel = z.infer<typeof ForestModel>;

// A flattened forest node: its server metadata plus the row's identity + indent depth.
// Frontend-derived (flattenForest), not a wire shape — hence a plain type, not a schema.
export type SpineNode = NodeMeta & { id: string; depth: number };

export const NodeData = z.object({
  branch: z.string(),
  files: z.array(FileDiff),
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
});
export type PR = z.infer<typeof PR>;

export const Project = z.object({
  name: z.string(),
  branches: z.number(),
  behind: z.number(),
  merged: z
    .object({ pr: z.number(), title: z.string(), at: z.string(), branch: z.string() })
    .nullable()
    .optional(), // most recent squash-merge into main attributed to this forest
});
export type Project = z.infer<typeof Project>;

// one (branch, forest) pair — the Cmd+K global jump index across all projects
export const ForestBranch = z.object({ branch: z.string(), project: z.string() });
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
});
export type Commit = z.infer<typeof Commit>;

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

export const SyncState = z.object({
  behind: z.number(), // commits on origin/main not yet in this branch
  syncable: z.boolean(), // safe to fast-forward-rebase (else stacked/published)
  why: z.string(), // when not syncable, the reason
  deployCritical: z.array(z.string()).optional(), // deploy-critical files origin/main changed that this branch lacks
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
