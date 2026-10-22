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

export interface Entities {
  repo: Record<string, Repo>;
  project: Record<string, Project>;
  branch: Record<string, Branch>;
  pr: Record<string, Pr>;
  landed: Record<string, Landed>;
}

export type EntityType = keyof Entities;
export type Domain = "git" | "remote";
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
