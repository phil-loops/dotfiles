// A gates run as the push screen shows it: each gate queued, running (and for how long), green or
// red — from the run's own event journal (GET /gates-progress), so a run that died without a
// result says so instead of looking like one still going. Pure.

export interface GateEvent {
  event: "plan" | "start" | "done" | "result" | string;
  gate?: string;
  gates?: string[] | { name: string; ok: boolean; ms: number; summary?: string }[];
  ok?: boolean;
  ms?: number;
  ts?: number;
}
export interface Progress {
  running: boolean;
  elapsed?: number;
  events?: GateEvent[];
  dead?: boolean;
  err?: string;
}
export interface GateRow {
  name: string;
  state: "queued" | "running" | "green" | "red" | "stopped";
  /** how long it ran, or has been running (ms) */
  ms: number | null;
  summary?: string;
}

/** Each planned gate's state; `now` (seconds, like the journal's ts) times a running one. */
export function gateRows(p: Progress | null | undefined, now: number): GateRow[] {
  const ev = p?.events ?? [];
  const plan = (ev.find((e) => e.event === "plan")?.gates as string[] | undefined) ?? [];
  const result = ev.find((e) => e.event === "result");
  const summaries = new Map(((result?.gates ?? []) as { name: string; summary?: string }[]).map((g) => [g.name, g.summary]));
  return plan.map((name) => {
    const done = ev.find((e) => e.event === "done" && e.gate === name);
    if (done) return { name, state: done.ok ? "green" : "red", ms: done.ms ?? null, summary: summaries.get(name) || undefined };
    const start = ev.find((e) => e.event === "start" && e.gate === name);
    if (start) return { name, state: p?.running ? "running" : "stopped", ms: start.ts ? Math.max(0, (now - start.ts) * 1000) : null };
    return { name, state: p?.running ? "queued" : "stopped", ms: null };
  });
}
