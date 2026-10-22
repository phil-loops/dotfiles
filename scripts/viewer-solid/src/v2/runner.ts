// The command runner — the one way an action happens, and so the one place actions are measured.
// A run applies its effect in the same frame (a local change, or a write's optimistic overlay),
// posts the write in the background on a FIFO queue (so five commands in a row never wait on each
// other), keeps the overlay until the server's copy agrees, and rolls back with a quiet line if
// the server refuses. Every run emits one `cmd` event: feedbackMs (input → the frame that paints
// the change) and settledMs (input → the server's answer) for free, by being registered.
import { createSignal } from "solid-js";
import { BUDGETS, PAINT_MS } from "./budgets";
import { commands, getCommand, type Via, type Write } from "./registry";
import { addOps, dropOps, onChange } from "./store";
import { post, type Sent } from "./sync";
import { emit, nextPaint } from "./telemetry";
import { model } from "./model";
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
const undo: { id: string; target: string }[] = [];
const SETTLE_WAIT = 5000;

// a write whose POST is answered but whose patch hasn't arrived keeps its overlay until it does
const awaiting = new Map<number, { settled: () => boolean; done: () => void }>();
onChange(() => {
  for (const [s, a] of awaiting) if (a.settled()) a.done();
});

export interface RunOpts {
  target?: string;
  event?: Event;
  /** set when `u` runs an inverse, so it doesn't stack an inverse of its own */
  undoing?: boolean;
}

/** Run a registered command. Never awaited by callers — the UI has already moved. */
export function dispatch(id: string, via: Via, opts: RunOpts = {}): void {
  const cmd = getCommand(id);
  if (!cmd) return;
  if (via === "menu" || via === "palette") setMenuOpen(false);
  const t0 = opts.event?.timeStamp ?? performance.now();
  const target = opts.target ?? (cmd.scope === "project" ? model.selected() : undefined);
  if (cmd.available && !cmd.available(target)) return;
  const base = { type: "cmd", id, budget: cmd.budget, via, ...(target ? { target } : {}) };
  const feedback = nextPaint(t0);

  if (cmd.local) {
    try {
      cmd.local(target, opts.event);
      void feedback.then((feedbackMs) => emit({ ...base, outcome: "ok", feedbackMs, settledMs: null }));
    } catch (e) {
      // a local command throws to refuse ("nothing to undo"); the message is the quiet line
      const err = e instanceof Error ? e.message : String(e);
      say(err);
      void feedback.then((feedbackMs) => emit({ ...base, outcome: "refused", err: err.slice(0, 48), feedbackMs, settledMs: null }));
    }
    return;
  }
  const w: Write | null = target && cmd.write ? cmd.write(target) : null;
  if (!w) return;
  const s = ++seq;
  addOps(w.ops.map((o) => ({ ...o, seq: s })));
  const sent: Promise<Sent> = queue.then(() => post(w.path, w.body));
  queue = sent;
  void sent.then(async (r) => {
    const settledMs = Math.round((performance.now() - t0) * 10) / 10;
    if (r.ok) {
      if (w.inverse && !opts.undoing) undo.push(w.inverse);
      if (w.said) say(w.said);
      reconcile(s, w);
    } else {
      dropOps(s);
      say(`${w.failed}${r.err && r.err !== "refused" ? ` — ${r.err.replaceAll("-", " ")}` : ""}`);
    }
    const feedbackMs = await feedback;
    emit({ ...base, outcome: r.outcome, ...(r.err ? { err: r.err } : {}), feedbackMs, settledMs, rid: r.rid });
  });
}

function reconcile(s: number, w: Write): void {
  if (w.settled()) return dropOps(s);
  const t = window.setTimeout(() => done(), SETTLE_WAIT);
  const done = () => {
    clearTimeout(t);
    awaiting.delete(s);
    dropOps(s);
  };
  awaiting.set(s, { settled: w.settled, done });
}

/** Put back the last write (one level per press). */
export function undoLast(): boolean {
  const inv = undo.pop();
  if (!inv) return false;
  dispatch(inv.id, "key", { target: inv.target, undoing: true });
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
