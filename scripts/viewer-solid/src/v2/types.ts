// The entities /state and /v2/events carry (srv/state.py; wiki canopy-v2-sync).
export type ProjectState = "focus" | "workbench" | "archive";

export interface Repo {
  id: string;
  name: string;
  main: string;
  trunk: string;
}

export interface Project {
  id: string;
  repo: string;
  name: string;
  state: ProjectState;
  rank: number | null;
  ticket: string | null;
  summary: string;
  size: number;
}

export interface Branch {
  id: string;
  repo: string;
  name: string;
  project: string;
  parent: string;
  parentId: string | null;
  description: string;
  subject: string;
  commits: number;
  tip: string;
  tree: string;
  pushed: "local" | "ahead" | "synced";
  ahead: number;
  gates: "green" | "red" | "running" | "stale" | "none";
  redGates: string[];
  /** position in its forest's merge order, 1-based */
  order: number;
  holdUntil: string | null;
  /** client-only: an optimistic write in flight ("pushing") */
  pending?: string;
}

export interface Pr {
  id: string;
  repo: string;
  branch: string;
  project: string;
  number: number;
  url: string;
  state: string;
  review: string | null;
  draft: boolean;
  base: string | null;
  approvals: number | null;
  mergeState: string | null;
  mergeable: string | null;
  approvedAt: string | null;
  title: string | null;
}

export interface Landed {
  id: string;
  repo: string;
  project: string;
  pr: number;
  title: string;
  branch: string;
  at: string;
}

// ── the review domain (srv/reviewdesk.py) ──

export interface Comment {
  id: string;
  author: string;
  body: string;
  at: string;
  url: string;
  /** PENDING while it sits in its author's unsubmitted review */
  state?: string;
  commit?: string;
  hunk?: string;
  reactions?: Record<string, number>;
}

export interface Note {
  verdict: "right" | "wrong" | "partly" | "unclear";
  evidence: { path: string; line: number; why: string }[];
  elsewhere: { path: string; line: number; branch?: string; why: string }[];
  cause: string | null;
  draftReply: string | null;
  model: string;
  at: string;
}

export interface Thread {
  id: string;
  repo: string;
  branch: string;
  pr: number;
  node: string;
  path: string;
  /** GitHub's anchor, on the PR head */
  line: number | null;
  startLine: number | null;
  originalLine: number | null;
  originalStartLine: number | null;
  side: "RIGHT" | "LEFT";
  subject: string;
  outdated: boolean;
  resolved: boolean;
  canResolve: boolean;
  canUnresolve: boolean;
  canReply: boolean;
  comments: Comment[];
  /** the anchor followed to the local tip; addressedBy names the commit that changed its lines */
  local: { line: number; startLine: number | null; addressedBy: string | null } | null;
  note: Note | null;
  /** client-only: a suggestion being applied */
  applying?: boolean;
}

export interface Review {
  id: string;
  author: string;
  state: string;
  body: string;
  at: string;
  url: string;
}

export interface Conv {
  id: string;
  repo: string;
  branch: string;
  number: number;
  title: string;
  body: string;
  url: string;
  author: string;
  state: string;
  headRef: string;
  base: string;
  head: string;
  tip: string;
  mapping: "same" | "walk" | "rewritten" | "unknown";
  unpushed: string[];
  viewer: string;
  reviews: Review[];
  comments: Comment[];
  pending: { id: string; count: number } | null;
  unflagged: { items: { path: string; line: number; why: string }[]; model: string; at: string } | null;
  at: number;
}

/** One thing Phil wrote, in the ledger (srv/reviewdesk.py): a comment on a line (or range), or a
 *  reply. `pending` / `submitted` are read off GitHub: in his pending review, or submitted by him. */
export interface Item {
  key: string;
  kind: "comment" | "reply";
  path?: string;
  side?: "RIGHT" | "LEFT";
  line?: number;
  startLine?: number | null;
  thread?: string;
  threadId?: string | null;
  body: string;
  state: "draft" | "waiting" | "sending" | "pending" | "submitted" | "gone";
  waitsFor: string[];
  err: string | null;
  send: boolean;
  at: string;
}

export interface Draft {
  id: string;
  repo: string;
  branch: string;
  items: Item[];
}

export interface Entities {
  repo: Record<string, Repo>;
  project: Record<string, Project>;
  branch: Record<string, Branch>;
  pr: Record<string, Pr>;
  landed: Record<string, Landed>;
  conv: Record<string, Conv>;
  thread: Record<string, Thread>;
  draft: Record<string, Draft>;
}

export type EntityType = keyof Entities;
export type Domain = "git" | "remote" | "review";
export type Versions = Record<Domain, number>;

export interface Snapshot {
  epoch: string;
  versions: Versions;
  entities: Partial<Entities>;
  ms?: number;
}

export interface Patch {
  domain: Domain;
  version: number;
  upserts: Partial<Record<EntityType, Record<string, unknown>>>;
  deletes: Partial<Record<EntityType, string[]>>;
}
