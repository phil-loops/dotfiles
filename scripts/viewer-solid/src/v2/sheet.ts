// What the `?` sheet shows: the current surface's scopes, the ones live under the cursor first,
// then everywhere. Other surfaces' keys are left out — they don't work here.
export const SURFACE_SCOPES: Record<string, string[]> = {
  forests: ["branch", "project", "row", "forests"],
  review: ["history", "commit", "pending", "thread", "line", "gap", "review"],
  dashboard: ["dashboard"],
  todo: ["item", "todo"],
  forest: ["branch", "row", "forest", "project"],
  machine: ["server", "machine"],
  wiki: ["article", "wiki"],
  tutor: ["concept", "lesson", "session", "tutor"],
};

export const SCOPE_TITLES: Record<string, string> = {
  global: "Everywhere",
  forests: "On Forests",
  row: "On a forest or branch",
  project: "On a forest",
  branch: "On a branch",
  dashboard: "On the dashboard",
  review: "Reviewing a branch",
  line: "On a diff line",
  thread: "On a conversation",
  pending: "On a pending comment",
  gap: "On hidden lines",
  history: "In the history",
  commit: "In one commit",
  todo: "On the tracker",
  item: "On an item",
  forest: "On a forest's page",
  machine: "On the machine",
  server: "On a server",
  wiki: "On the wiki",
  article: "On a page in the list",
  tutor: "On the tutor",
  concept: "On a concept",
  lesson: "On a session you keep",
  session: "In a session",
};

export interface SheetCmd {
  id: string;
  title: string;
  scope: string;
  keys: string[];
  /** whether it would do something to what's under the cursor now */
  available: boolean;
}
export interface SheetLine {
  key: string;
  cmd: SheetCmd;
}

/** The `?` sheet as "what can I do right now": each key shown once, as the command it would run here
 *  — the narrowest live scope binding it, the keymap's own rule — split into what works on the
 *  thing under the cursor, what works anywhere, and the page's keys that do nothing at the moment. */
export function sheetNow(surface: string, live: string[], cmds: SheetCmd[]): { now: SheetLine[]; everywhere: SheetLine[]; notNow: SheetLine[] } {
  const mine = new Set([...(SURFACE_SCOPES[surface] ?? []), "global"]);
  const here = cmds.filter((c) => mine.has(c.scope) && c.keys.length);
  const rank = (c: SheetCmd) => (live.includes(c.scope) ? live.indexOf(c.scope) : Infinity);
  const winner = new Map<string, SheetCmd>();
  for (const c of [...here].sort((a, b) => rank(a) - rank(b))) {
    if (rank(c) === Infinity) continue;
    for (const k of c.keys) if (!winner.has(k)) winner.set(k, c);
  }
  const now: SheetLine[] = [];
  const everywhere: SheetLine[] = [];
  const shown = new Set<string>();
  const byScope = [...winner.entries()].sort(([, a], [, b]) => rank(a) - rank(b));
  for (const [key, cmd] of byScope) {
    if (!cmd.available || shown.has(cmd.id)) continue;
    (cmd.scope === "global" ? everywhere : now).push({ key: cmd.keys.filter((k) => winner.get(k) === cmd).join(" · ") || key, cmd });
    shown.add(cmd.id);
  }
  const notNow = here.filter((c) => !shown.has(c.id) && c.scope !== "global").map((cmd) => ({ key: cmd.keys.join(" · "), cmd }));
  return { now, everywhere, notNow };
}
