// The DATA SEAM. Every read the UI does goes through `provider` — never a bare
// fetch() for reads. Today only HttpProvider exists (hits the live Python server).
// The point of the seam: a StaticProvider that reads pre-baked /data/*.json drops in
// here for a static-site deploy (a frozen, slice-in-time snapshot that needs no live
// server or GitHub connection), and nothing else in the app has to change.
//
// `capabilities.mutate` lets the UI hide the live-only actions (bless / checkout /
// squash / restack / integrate / chat) in static mode instead of rendering dead ones.
import { z } from "zod";
import { fetchJSON } from "./api";
import {
  Commit,
  ForestModel,
  Head,
  NodeData,
  PR,
  Project,
  Purpose,
  RestackStatus,
  Standalone,
  SyncState,
} from "./types";

export interface Capabilities {
  mutate: boolean; // can the backend take POST actions (bless, checkout, restack, …)?
  live: boolean; // is the data live (vs a baked snapshot)?
}

export interface DataProvider {
  readonly capabilities: Capabilities;
  myPrs(): Promise<PR[]>;
  projects(): Promise<Project[]>;
  standalone(): Promise<Standalone[]>;
  branches(): Promise<string[]>;
  model(branch: string): Promise<ForestModel>;
  node(branch: string, base?: string): Promise<NodeData>;
  commits(branch: string): Promise<Commit[]>;
  purpose(branch: string): Promise<Purpose>;
  head(): Promise<Head>;
  sync(branch: string): Promise<SyncState>;
  restackStatus(project?: string): Promise<RestackStatus>;
}

// Validate at the boundary. In live mode this is NON-FATAL: a drift between the
// Python emitter and these schemas is logged (so we notice) but the raw data still
// flows, so a schema lag never takes the running app down. The bake step will parse
// strictly instead, failing the build on invalid blobs.
function parse<S extends z.ZodType>(schema: S, data: unknown, label: string): z.infer<S> {
  const r = schema.safeParse(data);
  if (!r.success) {
    console.warn(`[provider] ${label}: schema mismatch (using raw)`, r.error.issues, data);
    return data as z.infer<S>;
  }
  return r.data;
}

const q = (s: string): string => encodeURIComponent(s);

export class HttpProvider implements DataProvider {
  readonly capabilities: Capabilities = { mutate: true, live: true };

  myPrs = () => fetchJSON<unknown>("/myprs").then((d) => parse(z.array(PR), d, "myprs"));
  projects = () => fetchJSON<unknown>("/projects").then((d) => parse(z.array(Project), d, "projects"));
  standalone = () => fetchJSON<unknown>("/standalone").then((d) => parse(z.array(Standalone), d, "standalone"));
  branches = () => fetchJSON<unknown>("/branches").then((d) => parse(z.array(z.string()), d, "branches"));
  model = (branch: string) => fetchJSON<unknown>("/model?branch=" + q(branch)).then((d) => parse(ForestModel, d, "model"));
  node = (branch: string, base?: string) =>
    fetchJSON<unknown>("/node?branch=" + q(branch) + (base ? "&base=" + base : "")).then((d) => parse(NodeData, d, "node"));
  commits = (branch: string) => fetchJSON<unknown>("/commits?branch=" + q(branch)).then((d) => parse(z.array(Commit), d, "commits"));
  purpose = (branch: string) => fetchJSON<unknown>("/purpose?branch=" + q(branch)).then((d) => parse(Purpose, d, "purpose"));
  head = () => fetchJSON<unknown>("/head").then((d) => parse(Head, d, "head"));
  sync = (branch: string) => fetchJSON<unknown>("/sync?branch=" + q(branch)).then((d) => parse(SyncState, d, "sync"));
  restackStatus = (project?: string) =>
    fetchJSON<unknown>("/restack-status" + (project ? "?project=" + q(project) : "")).then((d) => parse(RestackStatus, d, "restack-status"));
}

// The one place a provider is chosen. A future StaticProvider lands behind a
// build-time flag here; consumers import `provider` and never see the difference.
export const provider: DataProvider = new HttpProvider();
