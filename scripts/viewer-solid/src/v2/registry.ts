// The command registry: every action the app can take is one of these. Keys, buttons, the space
// menu and (later) the palette all dispatch by id through the runner, which times and records each
// run; the `?` sheet, the menu and the dashboard's never-used list are all generated from here.
import type { BudgetClass } from "./budgets";
import type { Op } from "./store";

/** Where a command applies, narrowest last: everywhere, on a surface, on the selected row (forest
 *  or branch), on its forest, on a branch. A key binds once per scope; the narrowest live one wins. */
export type Scope = "global" | "forests" | "dashboard" | "row" | "project" | "branch";
export type Via = "key" | "click" | "palette" | "menu" | "drag";

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
  /** the command that puts it back, for `u` */
  inverse?: { id: string; target: string; arg?: unknown };
}

export interface Command {
  id: string;
  title: string;
  scope: Scope;
  budget: BudgetClass;
  keys?: string[];
  /** v1 telemetry ids this replaces, so the dashboard can put the two side by side */
  v1?: string[];
  /** left out of the space menu (cursor motion, the menu itself) */
  quiet?: boolean;
  available?: (target: string | undefined) => boolean;
  /** a key that means "the right thing here" (↵): names the command that actually runs, which is
   *  the one recorded — so telemetry counts pushes, not presses of ↵ */
  route?: (target: string | undefined) => string | null;
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
