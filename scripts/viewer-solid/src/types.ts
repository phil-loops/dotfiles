// Wire shapes returned by the Python review server (stack-review-server.py + srv/*).
// These mirror the JSON each endpoint emits; keep them in sync when the server changes.

export interface NodeMeta {
  parent?: string;
  children?: string[];
  requires?: string[];
  stale: number;
  total: number;
  clean: number;
}

export interface ForestModel {
  nodes?: Record<string, NodeMeta>;
  roots?: string[];
  links?: { branch: string }[];
}

// A flattened forest node: its server metadata plus the row's identity + indent depth.
export interface SpineNode extends NodeMeta {
  id: string;
  depth: number;
}

export interface FileDiff {
  path: string;
  status: string; // "clean" | "blessed" | "added" | "modified" | …
  add?: number;
  del?: number;
  patch?: string;
}

export interface NodeData {
  branch: string;
  files: FileDiff[];
}

export interface PR {
  num: number;
  title: string;
  url: string;
  project: string;
  branch: string;
  draft?: boolean;
  review?: string | null; // "APPROVED" | "CHANGES_REQUESTED" | null
}

export interface Project {
  name: string;
  branches: number;
  behind: number;
}

export interface Standalone {
  branch: string;
  commits: number;
  add: number;
  del: number;
}

export interface Purpose {
  thesis: string;
  enables?: string;
  source?: string;
}

export interface Commit {
  sha: string;
  subject: string;
  author: string;
  date: string;
}

export interface RestackStatus {
  running: boolean;
  paused?: boolean;
  project?: string;
  current?: string;
  reason?: string;
}

export interface Parked {
  project: string;
  current: string;
  reason: string;
}
