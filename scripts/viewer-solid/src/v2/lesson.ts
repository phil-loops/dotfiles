// A tutor session as the page reads it (srv/tutor.py, scripts/learning.py): the learner's concept
// graph, the session's turns, and a turn split into prose and the fenced blocks the page draws
// instead of text — tutor-pin (code to show), tutor-options (answers to pick), tutor-rung (what's
// being tested), tutor-evidence (what the turn recorded), tutor-map, tutor-restate, tutor-question.
// Map, evidence and calibration are applied to the graph by the server when a turn ends. Pure.

export interface Msg {
  role: "tutor" | "me";
  text: string;
}
export interface Pin {
  path: string;
  ref?: string;
  lines?: [number, number];
}
/** A session, kept in this browser only (localStorage `tutor:sessions:v1`, shared with v1's page). */
export interface Session {
  id: string;
  target: string;
  created: number;
  /** the claude session a turn resumes */
  sessionId: string;
  msgs: Msg[];
  topic?: string;
  /** the turn streaming now — a reload re-attaches to it */
  pendingTurn?: string;
  error?: string;
  saved?: boolean;
  /** a picked-up terminal session's worktree — its claude session resumes only there */
  cwd?: string;
  /** the next turn forks the terminal session instead of resuming it in place */
  forkNext?: boolean;
  /** the instructions version this claude session has seen (a resume drops --append-system-prompt) */
  primed?: string | boolean;
  lastActive?: number;
  importedFrom?: string;
}
export interface TerminalSession {
  session: string;
  cwd: string;
  target: string;
  mtime: number;
  answers: number;
  last: string;
}
export interface ImportReply {
  session: string;
  cwd: string;
  target: string;
  msgs: Msg[];
  err?: string;
}
export interface CodeSrc {
  path: string;
  ref: string;
  text: string;
  err?: string;
}

export interface Mastery {
  depth: number;
  assisted: number;
  level: string;
  evidence: number;
  last: string;
  due: boolean;
  reason: string;
  open_miss: string;
  held?: number;
  held_level?: string;
  miss_confidence?: string;
  contrast?: string;
}
export interface Concept {
  id: string;
  name: string;
  statement: string;
  kind: "principle" | "convention";
  builds_on: string[];
  built_on_by: string[];
  analogs: string[];
  code: { path: string; ref?: string; lines?: number[] }[];
  topics: string[];
  mastery: Mastery;
  blocked_by?: string[];
  statement_learner?: string;
  restated?: string;
}
export interface Topic {
  id: string;
  title: string;
  source: string;
  stages: { name: string; concepts: string[] }[];
  progress: { held: number; shown?: number; total: number };
  updated?: string;
}
export interface Evidence {
  id: string;
  concept: string;
  level: string;
  credit: string;
  outcome: "hit" | "miss";
  note: string;
  at: string;
  topic: string;
  session: string;
  confidence?: string;
  rung?: string;
  contrast?: string;
  via?: string;
}
export interface Question {
  id: string;
  text: string;
  concept: string;
  topic: string;
  asked: string;
  status: "open" | "answered";
}
export interface LearnState {
  concepts: Record<string, Concept>;
  topics: Record<string, Topic>;
  due: string[];
  questions: Question[];
  evidence: Evidence[];
}

export const LEVELS = ["predict", "explain", "transfer", "critique"];
export const CREDITS = ["unaided", "scaffolded", "handed"];
export const CONFIDENCES = ["low", "medium", "high"];
export const LEVEL_HINT: Record<string, string> = {
  predict: "said what happens in a situation",
  explain: "said why",
  transfer: "handled it cold in a new setting",
  critique: "spotted it, or its absence, in real code",
};

export interface EvidenceBlock {
  concept: string;
  level: string;
  credit: string;
  outcome: string;
  note: string;
  confidence: string;
  contrast: string;
  via: string;
}
export type Seg =
  | { kind: "prose"; text: string }
  | { kind: "pin"; pin: Pin }
  | { kind: "options"; options: string[] }
  | { kind: "rung"; concept: string; level: string; rung: string; confidence: boolean; via: string; contrastOf: string }
  | { kind: "evidence"; items: EvidenceBlock[] }
  | { kind: "map"; title: string; count: number }
  | { kind: "restate"; concept: string; text: string }
  | { kind: "question"; concept: string; text: string }
  /** a projection scenario frozen before its reveal; `off` names the safeguards switched off */
  | { kind: "sim"; scenario: string; off: string[] }
  /** the learner's answer to a sim, played: what the system did */
  | { kind: "simResult"; scenario: string; off: string[]; outcome: string; divergence: { event: string; kind: string }[] }
  | { kind: "quiet" };

const FENCE = /```tutor-(pin|options|rung|evidence|map|calibration|restate|question|ledger|sim-result|sim)[ \t]*\r?\n([\s\S]*?)```/g;
const offOf = (k: unknown): string[] => Object.entries((k ?? {}) as Record<string, unknown>).filter(([, on]) => on === false).map(([name]) => name);
const asList = (v: unknown): string[] => (Array.isArray(v) ? v.map((x) => String(x)).filter((x) => x.trim()) : []);

/** A turn as prose and blocks. A fence still streaming in (no closing ```) is held back, never flashed as JSON. */
export function segments(text: string): Seg[] {
  const open = text.lastIndexOf("```tutor-");
  if (open >= 0 && !text.slice(open + 9).includes("```")) text = text.slice(0, open);
  const out: Seg[] = [];
  let last = 0;
  for (const m of text.matchAll(FENCE)) {
    if (m.index! > last) out.push({ kind: "prose", text: text.slice(last, m.index) });
    last = m.index! + m[0].length;
    let data: unknown;
    try {
      data = JSON.parse(m[2]);
    } catch {
      out.push({ kind: "prose", text: m[0] });
      continue;
    }
    const d = (data ?? {}) as Record<string, unknown>;
    if (m[1] === "pin" && typeof d.path === "string") {
      const lines = Array.isArray(d.lines) && d.lines.length >= 1 ? ([Number(d.lines[0]), Number(d.lines[1] ?? d.lines[0])] as [number, number]) : undefined;
      out.push({ kind: "pin", pin: { path: d.path, ref: d.ref ? String(d.ref) : undefined, lines } });
    } else if (m[1] === "options") {
      out.push({ kind: "options", options: asList(data) });
    } else if (m[1] === "rung" && d.concept) {
      out.push({
        kind: "rung",
        concept: String(d.concept),
        level: String(d.level ?? ""),
        rung: String(d.rung ?? ""),
        confidence: d.confidence === true,
        via: String(d.via ?? ""),
        contrastOf: String(d.contrast_of ?? ""),
      });
    } else if (m[1] === "evidence") {
      const items = (Array.isArray(data) ? data : [data])
        .map((e) => {
          const x = (e ?? {}) as Record<string, unknown>;
          return {
            concept: String(x.concept ?? ""),
            level: String(x.level ?? ""),
            credit: String(x.credit ?? "unaided"),
            outcome: String(x.outcome ?? "hit"),
            note: String(x.note ?? ""),
            confidence: String(x.confidence ?? ""),
            contrast: String(x.contrast ?? ""),
            via: String(x.via ?? ""),
          };
        })
        .filter((e) => e.concept);
      out.push({ kind: "evidence", items });
    } else if (m[1] === "sim" && typeof d.scenario === "string") {
      out.push({ kind: "sim", scenario: d.scenario, off: offOf(d.kernels) });
    } else if (m[1] === "sim-result" && typeof d.scenario === "string") {
      const divergence = (Array.isArray(d.divergence) ? d.divergence : []).map((x) => ({ event: String((x as Record<string, unknown>)?.event ?? ""), kind: String((x as Record<string, unknown>)?.kind ?? "") }));
      out.push({ kind: "simResult", scenario: d.scenario, off: offOf(d.kernels), outcome: String(d.outcome ?? ""), divergence });
    } else if (m[1] === "map") {
      const t = (d.topic ?? {}) as Record<string, unknown>;
      const stages = Array.isArray(d.stages) ? (d.stages as { concepts?: unknown[] }[]) : [];
      out.push({ kind: "map", title: String(t.title ?? t.id ?? "topic"), count: stages.reduce((n, s) => n + (s.concepts?.length ?? 0), 0) });
    } else if (m[1] === "restate" || m[1] === "question") {
      for (const x of Array.isArray(data) ? data : [data]) {
        const r = (typeof x === "string" ? { text: x } : (x ?? {})) as Record<string, unknown>;
        if (r.text) out.push({ kind: m[1], concept: String(r.concept ?? ""), text: String(r.text) });
      }
    } else {
      out.push({ kind: "quiet" }); // calibration, and the retired ledger in old sessions
    }
  }
  if (last < text.length) out.push({ kind: "prose", text: text.slice(last) });
  return out;
}

/** The fence the tab appends to an answer once it has played the sim: the tutor copies it into its evidence. */
export const simResultFence = (r: { scenario: string; off: string[]; outcome: string; divergence: { event: string; kind: string }[] }): string =>
  "```tutor-sim-result\n" + JSON.stringify({ scenario: r.scenario, kernels: Object.fromEntries(r.off.map((k) => [k, false])), outcome: r.outcome, divergence: r.divergence }) + "\n```";

/** What the learner said, without the machine fences the tab added to it. */
export const spoken = (text: string): string => proseOf(text).join("").trim();

const proseOf = (text: string) =>
  segments(text)
    .filter((x): x is Extract<Seg, { kind: "prose" }> => x.kind === "prose")
    .map((x) => x.text);

/** The one line a folded rung shows: the question it asked (its last "?" sentence), else its opening. */
export function askOf(text: string): string {
  const prose = proseOf(text)
    .join(" ")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/[*_`#>|]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  const asks = prose.match(/[^.?!]*\?/g);
  const line = (asks ? asks[asks.length - 1] : prose).trim();
  return line.length > 160 ? line.slice(0, 157) + "…" : line || "(no text)";
}

/** The whole paragraph holding a turn's last question, as asked. */
export function questionOf(text: string): string {
  const paras = proseOf(text)
    .flatMap((t) => t.split(/\n\s*\n/))
    .map((p) => p.replace(/[*_`#>|]/g, "").replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const q = [...paras].reverse().find((p) => p.includes("?")) ?? paras[paras.length - 1] ?? "";
  return q.length > 420 ? q.slice(0, 417) + "…" : q;
}

/** The newest block of a kind across the tutor's turns. */
export function latest<K extends Seg["kind"]>(msgs: Msg[], kind: K): Extract<Seg, { kind: K }> | null {
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role !== "tutor") continue;
    const hits = segments(msgs[i].text).filter((s) => s.kind === kind);
    if (hits.length) return hits[hits.length - 1] as Extract<Seg, { kind: K }>;
  }
  return null;
}

/** A rung is one tutor turn and the answer that followed it. */
export function rungsOf(msgs: Msg[]): { n: number; tutorIdx: number; answer?: string }[] {
  const out: { n: number; tutorIdx: number; answer?: string }[] = [];
  msgs.forEach((m, i) => {
    if (m.role === "tutor") out.push({ n: out.length + 1, tutorIdx: i, answer: msgs[i + 1]?.role === "me" ? msgs[i + 1].text : undefined });
  });
  return out;
}

/** Complete server-sent-event frames off the front of a buffer; what's left is a frame still arriving. */
export function sseFrames(buf: string): { frames: { event: string; data: string }[]; rest: string } {
  const frames: { event: string; data: string }[] = [];
  let nl: number;
  while ((nl = buf.indexOf("\n\n")) >= 0) {
    const frame = buf.slice(0, nl);
    buf = buf.slice(nl + 2);
    let event = "message";
    let data = "";
    for (const ln of frame.split("\n")) {
      if (ln.startsWith("event:")) event = ln.slice(6).trim();
      else if (ln.startsWith("data:")) data += ln.slice(5).trim();
    }
    if (data) frames.push({ event, data });
  }
  return { frames, rest: buf };
}

/** A concept's depth in words, for the pips' title. */
export function pipsTitle(m: Mastery): string {
  const parts = [];
  if (m.held) parts.push(`held at ${m.held_level} (two days)`);
  if (m.depth && (m.held ?? 0) < m.depth) parts.push(`shown once at ${m.level}`);
  if (!m.depth) parts.push("not yet shown unaided");
  if (m.assisted > m.depth) parts.push(`${LEVELS[m.assisted - 1]} with help`);
  if (m.open_miss) parts.push(`open miss${m.miss_confidence === "high" ? " (confident)" : ""}`);
  if (m.due) parts.push(`due: ${m.reason}`);
  return parts.join(" · ");
}

export function ago(ms: number, now = Date.now()): string {
  const m = Math.round((now - ms) / 60_000);
  if (m < 1) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  return new Date(ms).toLocaleDateString();
}
