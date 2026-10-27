// The command registry: every action the app can take is one of these. Keys, buttons, the space
// menu and (later) the palette all dispatch by id through the runner, which times and records each
// run; the `?` sheet, the menu and the dashboard's never-used list are all generated from here.
import type { BudgetClass } from "./budgets";
import type { Op } from "./store";

/** Where a command applies, narrowest last: everywhere, on a surface, on the selected row (forest
 *  or branch), on its forest, on a branch; on the review page, the page itself, the cursor's diff
 *  line, the thread or the pending comment under it; on the tracker, the page and the item under the cursor; on the machine, the page and the server under the cursor. A key binds once per scope; the narrowest live one wins. */
export type Scope = "global" | "forests" | "dashboard" | "row" | "project" | "branch" | "review" | "line" | "thread" | "pending" | "todo" | "item" | "forest" | "gap" | "history" | "commit" | "machine" | "server";
export type Via = "key" | "click" | "palette" | "menu" | "drag";

export type Inverse = { id: string; target: string; arg?: unknown };

/** An optimistic server write: shown at once, posted in the background, kept until settled. */
export interface Write {
  ops: Omit<Op, "seq">[];
  path: string;
  body: unknown;
  /** true once the server's copy (not the overlay) reflects this write */
  settled: () => boolean;
  /** one quiet line after it lands (undo hint), and the line if it's refused */
  said?: string;
  failed: string;
  /** the command that puts it back, for `u` — or a function of the server's answer when only the
   *  answer knows (the commit a suggestion made) */
  inverse?: Inverse | ((answer: Record<string, unknown>) => Inverse | undefined);
  /** undo a local (non-store) part of the optimistic change when the server refuses */
  rollback?: () => void;
}

export interface Command {
  id: string;
  title: string;
  scope: Scope;
  budget: BudgetClass;
  keys?: string[];
  /** one word for the hint line ("line", "reply"); the title's first clause when absent */
  label?: string;
  /** its opposite (next ↔ previous): the hint line shows the two as one, "j/k line" */
  pair?: string;
  /** keys a component handles itself (the comment box's ⌘↵): shown in the ? sheet, never bound */
  hint?: string[];
  /** v1 telemetry ids this replaces, so the dashboard can put the two side by side */
  v1?: string[];
  /** left out of the space menu (cursor motion, the menu itself) */
  quiet?: boolean;
  available?: (target: string | undefined) => boolean;
  /** a key that means "the right thing here" (↵): names the command that actually runs, which is
   *  the one recorded — so telemetry counts pushes, not presses of ↵ */
  route?: (target: string | undefined) => string | { id: string; target: string } | null;
  local?: (target: string | undefined, e?: Event, arg?: unknown) => void;
  write?: (target: string, arg?: unknown) => Write | null;
}

const registry = new Map<string, Command>();

export function command(c: Command): Command {
  if (registry.has(c.id)) throw new Error(`command ${c.id} registered twice`);
  registry.set(c.id, c);
  return c;
}

export const commands = (): Command[] => [...registry.values()];
export const getCommand = (id: string): Command | undefined => registry.get(id);

/** The key a hint names for a command — its first, after your keys.toml — so on-page hints follow the keymap. */
export const keyOf = (id: string): string => glyph(registry.get(id)?.keys?.[0] ?? "space");

/** A key as it reads on screen: ⇧s for S (so it never passes for s), ⇥ tab, ↵ ret, ⌃k for C-k. */
export const glyph = (k: string): string =>
  k
    .split(" ")
    .map((t) => {
      const named = ({ tab: "⇥", ret: "↵", down: "↓", up: "↑", left: "←", right: "→" } as Record<string, string>)[t];
      if (named) return named;
      const m = /^([CA]-)?(.)$/u.exec(t);
      if (!m) return t;
      const mod = m[1] === "C-" ? "⌃" : m[1] === "A-" ? "⌥" : "";
      const ch = m[2];
      return mod + (ch !== ch.toLowerCase() ? `⇧${ch.toLowerCase()}` : ch);
    })
    .join(" ");
