// A toy SES projection the tutor plays instead of telling: a scenario scripts inserts, projector
// pages, crashes and handoffs; kernels switch each safeguard on or off; the result names every event
// that was skipped, counted twice, or left pinned past cleanup. Mirrors the real design's rules
// (models/email-send-metric-projection.ts in loops) at toy scale. Deterministic and pure.

export type Kernel = "atomicCommit" | "safetyLag" | "lock" | "shardBookmarks" | "fence" | "cutoffCheck" | "retireBookmark";
export type Kernels = Record<Kernel, boolean>;

export const kernelNames: Record<Kernel, string> = {
  atomicCommit: "counts and bookmark commit together",
  safetyLag: "readers skip rows newer than the safety lag",
  lock: "one transaction per bookmark (advisory lock)",
  shardBookmarks: "bookmarks belong to shards, not groups",
  fence: "activation fences the old global writer",
  cutoffCheck: "activation waits until the cutoff is past the global bookmark",
  retireBookmark: "a removed reader's bookmark is deleted",
};
export const allKernels: Kernels = {
  atomicCommit: true, safetyLag: true, lock: true, shardBookmarks: true, fence: true, cutoffCheck: true, retireBookmark: true,
};

/** Ticks a reader stays behind the clock; every scripted insert commits within fewer. */
export const Lag = 3;

export type Step = { note?: string } & (
  | { do: "insert"; id: string; shard?: number }
  /** stamped now, invisible until its commit — a slow ingest transaction */
  | { do: "begin"; id: string; shard?: number }
  | { do: "commit"; id: string }
  | { do: "tick"; n?: number }
  /** opens a page transaction on one bookmark, or on a group's bookmarks; `lag` overrides the kernel */
  | { do: "read"; worker: string; bookmark?: string; group?: number; lag?: number }
  | { do: "apply"; worker: string }
  | { do: "save"; worker: string }
  | { do: "crash"; worker: string }
  /** a Valkey group lease; a held lease makes the worker exit for the rest of the run */
  | { do: "lease"; worker: string; group: number }
  /** the lease key vanishes (expiry, Valkey restart) while its worker keeps running */
  | { do: "leaseLost"; worker: string }
  | { do: "regroup"; groupCount: number }
  | { do: "activate" }
  /** the operator stops and drains the old global deployment */
  | { do: "stopGlobal" }
  | { do: "dropReader"; bookmark: string }
  | { do: "cleanup" }
);

export interface Scenario {
  id: string;
  title: string;
  /** the graph standard and concepts this scenario is evidence for */
  standard: string;
  concepts: string[];
  /** the safeguard a contrast flips; null when the scenario holds with every kernel on */
  kernel: Kernel | null;
  /** the situation as posed before the reveal, and the question */
  situation: string;
  question: string;
  shards?: number;
  groupCount?: number;
  pageSize?: number;
  /** bookmarks present at the start: "global", "audit", or "layout" (shard or group bookmarks per kernel) */
  bookmarks: string[];
  steps: Step[];
  /** steps before this index are the setup the learner sees frozen */
  revealAt: number;
}

export interface Cursor {
  stamp: number;
  id: string;
}
export interface SimEvent {
  id: string;
  shard: number;
  stamp: number;
  committed: boolean;
  retained: boolean;
  /** times each projection counted it */
  applied: Record<string, number>;
}
export interface Bookmark {
  name: string;
  projection: string;
  shards: number[];
  cursor: Cursor;
  /** false once stopped, dropped or orphaned by a regroup; the row may still exist */
  live: boolean;
}
export interface Worker {
  id: string;
  status: "idle" | "reading" | "busy" | "crashed" | "exited";
  lease: number | null;
  txn: { bookmarks: string[]; page: Record<string, string[]>; applied: boolean } | null;
}
export interface SimState {
  clock: number;
  groupCount: number;
  events: SimEvent[];
  bookmarks: Bookmark[];
  workers: Worker[];
  leases: Record<number, string>;
  cleaned: boolean;
  log: string[];
}
export interface Divergence {
  event: string;
  kind: "skipped" | "double" | "pinned";
}
export interface Result {
  outcome: "green" | "red";
  /** metric counts there should be so far, and there are */
  truth: number;
  actual: number;
  divergence: Divergence[];
  /** pages a worker couldn't start because another held the bookmark */
  busy: number;
}
export interface Sim {
  readonly scenario: Scenario;
  readonly kernels: Kernels;
  state(): SimState;
  done(): boolean;
  /** runs one step; returns its log line, or null when the script is over */
  step(): string | null;
  /** runs the setup and returns the frozen state the learner predicts from */
  toReveal(): SimState;
  runToEnd(): Result;
  result(): Result;
}

const Metrics = "metrics";

function cmp(a: Cursor, b: Cursor) {
  return a.stamp - b.stamp || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

function shardsOfGroup(shards: number, group: number, groupCount: number) {
  return Array.from({ length: shards }, (_, s) => s).filter((s) => s % groupCount === group);
}

export function createSim(scenario: Scenario, kernels: Partial<Kernels> = {}): Sim {
  const k: Kernels = { ...allKernels, ...kernels };
  const shardCount = scenario.shards ?? 1;
  const pageSize = scenario.pageSize ?? 10;
  const s: SimState = { clock: 0, groupCount: scenario.groupCount ?? 1, events: [], bookmarks: [], workers: [], leases: {}, cleaned: false, log: [] };
  let next = 0;
  let busy = 0;
  const start = { stamp: -1, id: "" };
  const all = Array.from({ length: shardCount }, (_, i) => i);

  const bookmark = (name: string) => s.bookmarks.find((b) => b.name === name);
  const addBookmark = (name: string, shards: number[], cursor: Cursor) => {
    const b = { name, projection: name === "audit" ? "audit" : Metrics, shards, cursor: { ...cursor }, live: true };
    s.bookmarks.push(b);
    return b;
  };
  const groupBookmark = (g: number) => `group-${g}/${s.groupCount}`;
  const coverage = (name: string) => {
    const shard = /^shard-(\d+)$/.exec(name);
    return shard ? [Number(shard[1])] : all;
  };
  for (const name of scenario.bookmarks) {
    if (name !== "layout") addBookmark(name, coverage(name), start);
    else if (k.shardBookmarks) all.forEach((sh) => addBookmark(`shard-${sh}`, [sh], start));
    else for (let g = 0; g < s.groupCount; g++) addBookmark(groupBookmark(g), shardsOfGroup(shardCount, g, s.groupCount), start);
  }

  const worker = (id: string) => {
    let w = s.workers.find((x) => x.id === id);
    if (!w) s.workers.push((w = { id, status: "idle", lease: null, txn: null }));
    return w;
  };
  const lockHolder = (name: string, except?: Worker) =>
    s.workers.find((w) => w !== except && w.txn?.bookmarks.includes(name));
  const pos = (e: SimEvent): Cursor => ({ stamp: e.stamp, id: e.id });
  const applyCounts = (w: Worker) => {
    for (const [name, ids] of Object.entries(w.txn!.page)) {
      const projection = bookmark(name)!.projection;
      for (const id of ids) {
        const e = s.events.find((x) => x.id === id)!;
        e.applied[projection] = (e.applied[projection] ?? 0) + 1;
      }
    }
  };
  const insert = (id: string, shard: number, committed: boolean) =>
    s.events.push({ id, shard, stamp: s.clock, committed, retained: true, applied: {} });

  function read(w: Worker, step: Extract<Step, { do: "read" }>) {
    if (w.status === "exited") return `${w.id} has exited`;
    const names =
      step.bookmark !== undefined
        ? [step.bookmark]
        : k.shardBookmarks
          ? shardsOfGroup(shardCount, step.group!, s.groupCount).map((sh) => `shard-${sh}`)
          : [groupBookmark(step.group!)];
    for (const name of names) {
      const b = bookmark(name);
      if (b && !b.live && name === "global") return `${w.id} can't read global: the old writer is stopped`;
    }
    const held = k.lock ? names.find((n) => lockHolder(n, w)) : undefined;
    if (held) {
      busy++;
      w.status = "busy";
      return `${w.id} is busy: ${lockHolder(held, w)!.id} holds ${held}`;
    }
    const horizon = s.clock - (step.lag ?? (k.safetyLag ? Lag : 0));
    const page: Record<string, string[]> = {};
    for (const name of names) {
      const b =
        bookmark(name) ??
        addBookmark(name, step.bookmark !== undefined ? coverage(name) : shardsOfGroup(shardCount, step.group!, s.groupCount), { stamp: s.clock - Lag, id: "" });
      page[name] = s.events
        .filter((e) => e.committed && e.retained && b.shards.includes(e.shard) && e.stamp <= horizon && cmp(pos(e), b.cursor) > 0)
        .sort((a, b) => cmp(pos(a), pos(b)))
        .slice(0, pageSize)
        .map((e) => e.id);
    }
    w.status = "reading";
    w.txn = { bookmarks: names, page, applied: false };
    const ids = Object.values(page).flat();
    return `${w.id} reads ${names.join(", ")}: ${ids.length ? ids.join(" ") : "nothing ready"}`;
  }

  function apply(w: Worker) {
    if (!w.txn) return `${w.id} has no page open`;
    w.txn.applied = true;
    if (!k.atomicCommit) {
      applyCounts(w);
      return `${w.id} commits the counts (bookmark not saved yet)`;
    }
    return `${w.id} adds the counts in its open transaction`;
  }

  function save(w: Worker) {
    if (!w.txn) return `${w.id} has no page open`;
    if (k.atomicCommit && w.txn.applied) applyCounts(w);
    for (const [name, ids] of Object.entries(w.txn.page)) {
      const last = ids.at(-1);
      if (last) bookmark(name)!.cursor = pos(s.events.find((e) => e.id === last)!);
    }
    w.txn = null;
    w.status = "idle";
    return k.atomicCommit ? `${w.id} commits counts and bookmark together` : `${w.id} saves its bookmark`;
  }

  function activate() {
    const shardNames = all.map((sh) => `shard-${sh}`);
    if (shardNames.every((n) => bookmark(n))) return "shards already active";
    const global = bookmark("global");
    if (k.fence && lockHolder("global")) return `activation is busy: ${lockHolder("global")!.id} holds global`;
    const cutoff = { stamp: s.clock - Lag, id: "" };
    if (k.cutoffCheck && global && cutoff.stamp <= global.cursor.stamp)
      return `activation waits: cutoff ${cutoff.stamp} is not past the global bookmark ${global.cursor.stamp}`;
    shardNames.forEach((n, sh) => bookmark(n) ?? addBookmark(n, [sh], cutoff));
    if (k.fence && global) global.live = false;
    return `shards start at cutoff ${cutoff.stamp}${k.fence && global ? "; the old global writer is fenced" : ""}`;
  }

  function cleanup() {
    s.cleaned = true;
    if (!s.bookmarks.length) return "cleanup: no bookmarks, nothing removed";
    const floor = s.bookmarks.reduce((m, b) => (cmp(b.cursor, m) < 0 ? b.cursor : m), s.bookmarks[0].cursor);
    const gone = s.events.filter((e) => e.retained && e.committed && cmp(pos(e), floor) < 0);
    gone.forEach((e) => (e.retained = false));
    return `cleanup removes everything before stamp ${floor.stamp}: ${gone.map((e) => e.id).join(" ") || "nothing"}`;
  }

  function run(step: Step): string {
    switch (step.do) {
      case "insert":
        insert(step.id, step.shard ?? 0, true);
        return `${step.id} lands at t${s.clock}${shardCount > 1 ? ` in shard ${step.shard ?? 0}` : ""}`;
      case "begin":
        insert(step.id, step.shard ?? 0, false);
        return `${step.id} is stamped t${s.clock} but its insert hasn't committed`;
      case "commit":
        s.events.find((e) => e.id === step.id)!.committed = true;
        return `${step.id} commits now (stamped earlier)`;
      case "tick":
        s.clock += step.n ?? 1;
        return `clock → t${s.clock}`;
      case "read":
        return read(worker(step.worker), step);
      case "apply":
        return apply(worker(step.worker));
      case "save":
        return save(worker(step.worker));
      case "crash": {
        const w = worker(step.worker);
        w.txn = null;
        w.status = "crashed";
        return `${w.id} crashes${k.atomicCommit ? "; its open transaction rolls back" : ""}`;
      }
      case "lease": {
        const w = worker(step.worker);
        const holder = s.leases[step.group];
        if (holder && holder !== w.id) {
          w.status = "exited";
          return `${w.id} can't lease group ${step.group} (${holder} holds it) and exits`;
        }
        s.leases[step.group] = w.id;
        w.lease = step.group;
        return `${w.id} leases group ${step.group}`;
      }
      case "leaseLost": {
        const w = worker(step.worker);
        if (w.lease !== null) delete s.leases[w.lease];
        w.lease = null;
        return `${w.id}'s lease key is gone; ${w.id} is still running`;
      }
      case "regroup": {
        const old = s.groupCount;
        s.groupCount = step.groupCount;
        s.bookmarks.filter((b) => b.name.endsWith(`/${old}`)).forEach((b) => (b.live = false));
        return `group count ${old} → ${step.groupCount}`;
      }
      case "activate":
        return activate();
      case "stopGlobal": {
        const g = bookmark("global");
        if (g) g.live = false;
        return "the old global deployment is stopped and drained";
      }
      case "dropReader": {
        const b = bookmark(step.bookmark);
        if (!b) return `no reader ${step.bookmark}`;
        b.live = false;
        if (k.retireBookmark) s.bookmarks.splice(s.bookmarks.indexOf(b), 1);
        return `reader ${step.bookmark} is removed${k.retireBookmark ? " with its bookmark" : "; its bookmark row stays"}`;
      }
      case "cleanup":
        return cleanup();
    }
  }

  function result(): Result {
    const divergence: Divergence[] = [];
    const live = s.bookmarks.filter((b) => b.live && b.projection === Metrics);
    let truth = 0;
    let actual = 0;
    for (const e of s.events) {
      const n = e.applied[Metrics] ?? 0;
      actual += n;
      if (n >= 2) divergence.push({ event: e.id, kind: "double" });
      const covering = live.filter((b) => b.shards.includes(e.shard));
      const passed = covering.length > 0 && covering.every((b) => cmp(b.cursor, pos(e)) >= 0);
      if (n === 0 && e.committed && passed) divergence.push({ event: e.id, kind: "skipped" });
      if (n > 0 || (e.committed && passed)) truth++;
    }
    const allLive = s.bookmarks.filter((b) => b.live);
    if (s.cleaned && allLive.length) {
      const floor = allLive.reduce((m, b) => (cmp(b.cursor, m) < 0 ? b.cursor : m), allLive[0].cursor);
      for (const e of s.events) if (e.retained && e.committed && cmp(pos(e), floor) < 0) divergence.push({ event: e.id, kind: "pinned" });
    }
    return { outcome: divergence.length ? "red" : "green", truth, actual, divergence, busy };
  }

  const sim: Sim = {
    scenario,
    kernels: k,
    state: () => structuredClone(s),
    done: () => next >= scenario.steps.length,
    step() {
      if (sim.done()) return null;
      const line = run(scenario.steps[next++]);
      s.log.push(line);
      return line;
    },
    toReveal() {
      while (next < scenario.revealAt) sim.step();
      return sim.state();
    },
    runToEnd() {
      while (sim.step() !== null);
      return result();
    },
    result,
  };
  return sim;
}
