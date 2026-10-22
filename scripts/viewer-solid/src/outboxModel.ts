// The outbox's data and the pure decisions over it: which lane a node sits in, and where the clock
// stands against the 15:00 PT cliff. Kept free of Solid so node --test can pin the rules.

export type Gates = "green" | "red" | "stale" | "running" | "none";
export type NodeStatus = "landed" | "approved" | "review" | "ready" | "work" | "empty";

export interface OutboxPR {
  number: number;
  url: string;
  state: "OPEN" | "MERGED" | "CLOSED";
  draft?: boolean;
  review?: string | null;
  mergeState?: string;
  mergeable?: string;
  approvals?: number;
  approvedAt?: string;
  createdAt?: string;
  title?: string;
}

export interface Waiting {
  kind: "parent" | "draft" | "conflicts" | "ci" | "behind" | "checks" | "merge";
  label: string;
  url: string;
}

export interface OutboxNode {
  branch: string;
  leaf: string;
  position: number;
  rank: number;
  parent: string;
  base: string;
  stackedOn: { branch: string; pr?: number | null } | null;
  requires: string[];
  after: string[];
  description: string;
  title: string;
  titleSource: "saved" | "commit" | "pr";
  subjects: string[];
  commits: number;
  pushed: "local" | "ahead" | "synced";
  ahead: number;
  gates: Gates;
  redGates: string[];
  pr: OutboxPR | null;
  status: NodeStatus;
  holdUntil: string;
  waitingOn?: Waiting[];
  waitingH?: number | null;
  compareUrl?: string;
}

export type ForestSummary = "ready-to-launch" | "launch-blocked" | "blocked" | "ready" | "approved-chain" | "in-review";

export interface OutboxForest {
  repo: string;
  project: string;
  ticket: string;
  summary: ForestSummary;
  size: number;
  unopened: number;
  focus: number | null;
  nodes: OutboxNode[];
}

export interface PushWindowFacts {
  cliffHourPT: number;
  slowH: number;
  fastH: number;
  serialForestH: number;
  morningHourPT: number;
}

export interface OutboxData {
  forests: OutboxForest[];
  window: PushWindowFacts;
  prSource: "gh" | "fixture";
  generatedAt: string;
  ms: number;
}

// ── the clock: ?now=<iso> pins it for screenshots and trials; it keeps ticking from there ──
const loadedAt = Date.now();
let pinned: number | null = null;
if (typeof window !== "undefined") {
  const raw = new URLSearchParams(window.location.search).get("now");
  const t = raw ? Date.parse(raw) : NaN;
  pinned = Number.isFinite(t) ? t : null;
}
export const clockNow = (): number => (pinned == null ? Date.now() : pinned + (Date.now() - loadedAt));

const PT = "America/Los_Angeles";

export interface PtParts { year: number; month: number; day: number; hour: number; minute: number; weekday: number }

export function ptParts(ms: number): PtParts {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: PT, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric",
    hour: "numeric", minute: "numeric", weekday: "short",
  }).formatToParts(new Date(ms));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(get("weekday"));
  return { year: +get("year"), month: +get("month"), day: +get("day"), hour: +get("hour") % 24, minute: +get("minute"), weekday: wd };
}

// PT wall-clock → epoch ms, using the zone offset in force at `near`.
function ptToMs(y: number, mo: number, d: number, h: number, near: number): number {
  const p = ptParts(near);
  const offset = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Math.floor(near / 60_000) * 60_000;
  return Date.UTC(y, mo - 1, d, h, 0) - offset;
}

/** The next weekday morning at `hour` PT — today's if it's still ahead of us. */
export function nextMorning(ms: number, hour: number): number {
  for (let i = 0; i < 8; i++) {
    const p = ptParts(ms + i * 86_400_000);
    if (p.weekday === 0 || p.weekday === 6) continue;
    const at = ptToMs(p.year, p.month, p.day, hour, ms);
    if (at > ms) return at;
  }
  return ms + 86_400_000;
}

export type WindowPhase = "open" | "closing" | "late" | "weekend";

export function pushWindow(ms: number, w: PushWindowFacts): { phase: WindowPhase; minutesToCliff: number; hourFloat: number } {
  const p = ptParts(ms);
  const hourFloat = p.hour + p.minute / 60;
  const minutesToCliff = Math.round((w.cliffHourPT - hourFloat) * 60);
  if (p.weekday === 0 || p.weekday === 6) return { phase: "weekend", minutesToCliff, hourFloat };
  if (minutesToCliff <= 0) return { phase: "late", minutesToCliff, hourFloat };
  return { phase: minutesToCliff <= 60 ? "closing" : "open", minutesToCliff, hourFloat };
}

export const fmtPT = (ms: number): string =>
  new Intl.DateTimeFormat("en-US", { timeZone: PT, hour: "numeric", minute: "2-digit" }).format(new Date(ms)).toLowerCase().replace(" ", "");

export const fmtDayPT = (ms: number): string =>
  new Intl.DateTimeFormat("en-US", { timeZone: PT, weekday: "short", hour: "numeric", minute: "2-digit" }).format(new Date(ms));

export const fmtSpan = (minutes: number): string => {
  const m = Math.max(0, Math.round(minutes));
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ""}`;
};

// ── lanes ──
export type Lane = "first" | "ready" | "launch" | "approved" | "review" | "work";

export const LANES: { id: Lane; title: string; ask: string }[] = [
  { id: "first", title: "first thing tomorrow", ask: "held past the cliff, waiting for a morning push" },
  { id: "ready", title: "ready to ship", ask: "green for this exact tree — push, then open the PR" },
  { id: "launch", title: "launch a forest", ask: "open every node at once instead of one merge at a time" },
  { id: "approved", title: "approved, waiting on…", ask: "the next human action for each" },
  { id: "review", title: "in review", ask: "on GitHub, nobody's approved yet" },
  { id: "work", title: "needs work", ask: "red, stale or never gated — /push-ready owns these" },
];

export type Item =
  | { kind: "node"; lane: Lane; forest: OutboxForest; node: OutboxNode }
  | { kind: "forest"; lane: Lane; forest: OutboxForest };

const unopened = (n: OutboxNode) => n.status === "ready" || n.status === "work";
export const isHeld = (n: OutboxNode) => !!n.holdUntil && unopened(n);
export const isDue = (n: OutboxNode, now: number) => isHeld(n) && Date.parse(n.holdUntil) <= now;

/** A multi-node forest with ≥2 nodes not yet on GitHub is launched as one, not row by row. */
export const isLaunch = (f: OutboxForest) => f.size > 1 && f.nodes.filter(unopened).length >= 2;

function nodeLane(n: OutboxNode): Lane | null {
  if (isHeld(n)) return "first";
  switch (n.status) {
    case "ready": return "ready";
    case "work": return "work";
    case "approved": return "approved";
    case "review": return "review";
    case "landed":
    case "empty": return null;
  }
}

/** Every outbox entry in lane order, forests in focus-then-name order, nodes in merge order. */
export function laneItems(data: OutboxData | undefined): Item[] {
  if (!data) return [];
  const forests = [...data.forests].sort((a, b) =>
    (a.focus ?? 1e9) - (b.focus ?? 1e9) || a.project.localeCompare(b.project));
  const byLane = new Map<Lane, Item[]>(LANES.map((l) => [l.id, []]));
  for (const f of forests) {
    if (isLaunch(f)) {
      const open = f.nodes.filter(unopened);
      const allHeld = open.every((n) => !!n.holdUntil);
      byLane.get(allHeld ? "first" : "launch")!.push({ kind: "forest", lane: allHeld ? "first" : "launch", forest: f });
      for (const n of f.nodes) {
        const lane = nodeLane(n);
        if (lane && !unopened(n)) byLane.get(lane)!.push({ kind: "node", lane, forest: f, node: n });
      }
      continue;
    }
    for (const n of f.nodes) {
      const lane = nodeLane(n);
      if (lane) byLane.get(lane)!.push({ kind: "node", lane, forest: f, node: n });
    }
  }
  return LANES.flatMap((l) => byLane.get(l.id)!);
}

export const itemKey = (it: Item): string =>
  it.kind === "forest" ? `${it.lane}:${it.forest.repo}/${it.forest.project}` : `${it.lane}:${it.forest.repo}/${it.node.branch}`;

/** The launch sheet's step state for one node. */
export type Step = "done" | "now" | "blocked" | "waiting";

export function launchSteps(n: OutboxNode, parent: OutboxNode | undefined): { push: Step; open: Step } {
  if (n.status === "landed" || n.pr) return { push: "done", open: "done" };
  const pushed = n.pushed === "synced";
  const parentReady = !parent || parent.status === "landed" || parent.pushed === "synced" || !!parent.pr;
  return {
    push: pushed ? "done" : n.gates !== "green" ? "blocked" : parentReady ? "now" : "waiting",
    open: !pushed ? "waiting" : "now",
  };
}

export const summaryLabel: Record<ForestSummary, string> = {
  "ready-to-launch": "ready to launch",
  "launch-blocked": "launch blocked",
  blocked: "blocked",
  ready: "ready to ship",
  "approved-chain": "approved chain",
  "in-review": "in review",
};
