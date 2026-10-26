// The command runner — the one way an action happens, and so the one place actions are measured.
// A run applies its effect in the same frame (a local change, or a write's optimistic overlay),
// posts the write in the background on a FIFO queue (so five commands in a row never wait on each
// other), keeps the overlay until the server's copy agrees, and rolls back with a quiet line if
// the server refuses. Every run emits one `cmd` event: feedbackMs (input → the frame that paints
// the change) and settledMs (input → the server's answer) for free, by being registered.
import { createSignal } from "solid-js";
import { BUDGETS, PAINT_MS } from "./budgets";
import { commands, getCommand, glyph, type Inverse, type Via, type Write } from "./registry";
import { addOps, dropOps, onChange } from "./store";
import { post, type Sent } from "./sync";
import { emit, nextPaint } from "./telemetry";
import { targetFor } from "./model";
import { setMenuOpen } from "./ui";

const [note, setNote] = createSignal<string | null>(null);
export { note };
let noteTimer: number | undefined;
function say(text: string): void {
  setNote(text);
  clearTimeout(noteTimer);
  noteTimer = window.setTimeout(() => setNote(null), 4000);
}

let seq = 0;
let queue: Promise<unknown> = Promise.resolve();
const undo: Inverse[] = [];
const SETTLE_WAIT = 5000;

// a write whose POST is answered but whose patch hasn't arrived keeps its overlay until it does
const awaiting = new Map<number, { settled: () => boolean; done: () => void }>();
onChange(() => {
  for (const [s, a] of awaiting) if (a.settled()) a.done();
});

export interface RunOpts {
  target?: string;
  event?: Event;
  /** what a drag or an undo carries beyond the target (a destination, the branches to let go) */
  arg?: unknown;
  /** set when `u` runs an inverse, so it doesn't stack an inverse of its own */
  undoing?: boolean;
  /** the command the key named, when a route sent it on to another (the push key → arm/confirm) */
  from?: string;
}

// ── what a key just did: the on-screen key labels light for a moment ──

/** The command a key just ran (ok) or that had nothing to do (not ok), for ~half a second. */
const [fired, setFired] = createSignal<{ id: string; ok: boolean; at: number } | null>(null);
export { fired };
let firedTimer: number | undefined;
function echo(id: string, via: Via, ok: boolean): void {
  if (via !== "key") return;
  const at = Date.now();
  setFired({ id, ok, at });
  clearTimeout(firedTimer);
  firedTimer = window.setTimeout(() => setFired((f) => (f?.at === at ? null : f)), ok ? 600 : 1400);
  if (!ok) say(`${glyph(getCommand(id)?.keys?.[0] ?? "")} · nothing here`);
}

/** Run a registered command. Never awaited by callers — the UI has already moved. */
export function dispatch(id: string, via: Via, opts: RunOpts = {}): void {
  const cmd = getCommand(id);
  if (!cmd) return;
  if (via === "menu" || via === "palette") setMenuOpen(false);
  const named = opts.from ?? id;
  if (cmd.route) {
    const next = cmd.route(opts.target ?? targetFor(cmd.scope));
    if (next && next !== id) dispatch(next, via, { ...opts, from: named });
    else echo(named, via, false);
    return;
  }
  const t0 = opts.event?.timeStamp ?? performance.now();
  const target = opts.target ?? targetFor(cmd.scope);
  if (cmd.available && !cmd.available(target)) return echo(named, via, false);
  const base = { type: "cmd", id, budget: cmd.budget, via, ...(target ? { target } : {}) };
  const feedback = nextPaint(t0);

  if (cmd.local) {
    try {
      cmd.local(target, opts.event, opts.arg);
      echo(named, via, true);
      void feedback.then((feedbackMs) => emit({ ...base, outcome: "ok", feedbackMs, settledMs: null }));
    } catch (e) {
      // a local command throws to refuse ("nothing to undo"); the message is the quiet line
      const err = e instanceof Error ? e.message : String(e);
      say(err);
      echo(named, via, false);
      void feedback.then((feedbackMs) => emit({ ...base, outcome: "refused", err: err.slice(0, 48), feedbackMs, settledMs: null }));
    }
    return;
  }
  let w: Write | null = null;
  try {
    w = target && cmd.write ? cmd.write(target, opts.arg) : null;
  } catch (e) {
    // a write throws to refuse before it sends ("write something first"), like a local command
    const err = e instanceof Error ? e.message : String(e);
    say(err);
    void feedback.then((feedbackMs) => emit({ ...base, outcome: "refused", err: err.slice(0, 48), feedbackMs, settledMs: null }));
    return;
  }
  echo(named, via, !!w);
  if (!w) return;
  const runKey = `${id}|${target ?? ""}`;
  const started = Date.now();
  setRun(runKey, { state: "sending", t0: started });
  const s = ++seq;
  addOps(w.ops.map((o) => ({ ...o, seq: s })));
  const sent: Promise<Sent> = queue.then(() => post(w.path, w.body, via));
  queue = sent;
  void sent.then(async (r) => {
    const settledMs = Math.round((performance.now() - t0) * 10) / 10;
    if (r.ok) {
      const inv = typeof w.inverse === "function" ? w.inverse(r.body ?? {}) : w.inverse;
      if (inv && !opts.undoing) undo.push(inv);
      if (w.said) say(w.said);
      setRun(runKey, { state: "landing", t0: started });
      reconcile(s, w, () => setRun(runKey, { state: "done", t0: started, t1: Date.now() }));
    } else {
      dropOps(s);
      w.rollback?.();
      // the server's own sentence says what to do next; the short class is the fallback
      const why = typeof r.body?.err === "string" && r.body.err.length <= 140 ? r.body.err : r.err && r.err !== "refused" ? r.err.replaceAll("-", " ") : "";
      say(`${w.failed}${why ? ` — ${why}` : ""}`);
      setRun(runKey, { state: "failed", t0: started, t1: Date.now(), err: `${w.failed}${why ? ` — ${why}` : ""}` });
    }
    const feedbackMs = await feedback;
    emit({ ...base, outcome: r.outcome, ...(r.err ? { err: r.err } : {}), feedbackMs, settledMs, rid: r.rid });
  });
}

function reconcile(s: number, w: Write, onDone?: () => void): void {
  if (w.settled()) {
    dropOps(s);
    return onDone?.();
  }
  const t = window.setTimeout(() => done(), SETTLE_WAIT);
  const done = () => {
    clearTimeout(t);
    awaiting.delete(s);
    dropOps(s);
    onDone?.();
  };
  awaiting.set(s, { settled: w.settled, done });
}

// ── a write's live state, for a button that becomes its own status ──

/** sending: the request is out · landing: the server said yes, the page is catching up ·
 *  done · failed (with the reason the quiet line also gave) */
export interface Run {
  state: "sending" | "landing" | "done" | "failed";
  t0: number;
  t1?: number;
  err?: string;
}
const [runs, setRuns] = createSignal<ReadonlyMap<string, Run>>(new Map());
const setRun = (k: string, r: Run) => setRuns((m) => new Map(m).set(k, r));
/** The latest run of command `id` on `target` this page load. */
export const runOf = (id: string, target: string | undefined): Run | undefined => runs().get(`${id}|${target ?? ""}`);

/** Put back the last write (one level per press). */
export function undoLast(): boolean {
  const inv = undo.pop();
  if (!inv) return false;
  dispatch(inv.id, "key", { target: inv.target, arg: inv.arg, undoing: true });
  return true;
}

/** The click handler for anything clickable: it dispatches a registered command. */
export const bind = (id: string, target?: string, via: Via = "click") => (e: MouseEvent) => {
  e.stopPropagation();
  dispatch(id, via, { target, event: e });
};

/** Once per page load: what exists to be used, and the budgets it's held to — the dashboard
 *  derives "never used" and every budget comparison from this, with no per-command code. */
export function announce(surfaces: { id: string; v1?: string[] }[]): void {
  emit({
    type: "registry",
    commands: commands().map((c) => ({ id: c.id, title: c.title, scope: c.scope, budget: c.budget, keys: c.keys ?? [], ...(c.v1 ? { v1: c.v1 } : {}) })),
    surfaces,
    budgets: BUDGETS,
    paintMs: PAINT_MS,
  });
}
