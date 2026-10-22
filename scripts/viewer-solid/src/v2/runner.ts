// The command runner — the one way an action happens, and so the one place actions are measured.
// A run applies its effect in the same frame; every run emits one `cmd` event with feedbackMs
// (input → the frame that paints the change) for free, by being registered.
import { createSignal } from "solid-js";
import { BUDGETS, PAINT_MS } from "./budgets";
import { commands, getCommand, type Via } from "./registry";
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

export interface RunOpts {
  target?: string;
  event?: Event;
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
      // a local command throws to refuse; the message is the quiet line
      const err = e instanceof Error ? e.message : String(e);
      say(err);
      void feedback.then((feedbackMs) => emit({ ...base, outcome: "refused", err: err.slice(0, 48), feedbackMs, settledMs: null }));
    }
  }
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
