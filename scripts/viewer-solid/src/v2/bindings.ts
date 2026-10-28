// Your keys over the defaults, and the one rule they must keep: a key means one thing on every
// page. Pure, so the test and the running app check the same way.
import { SURFACE_SCOPES } from "./sheet";

export interface Bound {
  id: string;
  scope: string;
  keys?: string[];
}

/** Commands that are the same move on different pages, each page doing it to its own things. */
export const SAME_MOVE: Record<string, string[]> = {
  "next": ["cursor.down", "review.down", "history.next"],
  "previous": ["cursor.up", "review.up", "history.prev"],
  "back out": ["overlay.close", "review.back", "history.exit", "commit.exit", "wiki.back", "tutor.back"],
  "out": ["forest.collapse", "review.leave", "forest.leave", "commit.back", "machine.log.close", "tutor.home"],
  "in": ["forest.expand", "branch.open", "history.enter", "machine.log"],
  "the thing's main action": ["row.primary", "review.fold", "todo.open", "review.expand", "history.open", "machine.open", "wiki.open", "tutor.concept", "tutor.open"],
  "send to GitHub": ["branch.push", "review.send", "review.push"],
  "move up the list": ["focus.up", "todo.up"],
  "move down the list": ["focus.down", "todo.down"],
  "put it away": ["project.archive", "todo.drop", "machine.kill", "tutor.forget"],
  "the words": ["review.words", "forest.words", "story.why"],
  "the page's other face": ["review.tab", "forest.face", "machine.log.jobs"],
  "open on GitHub": ["branch.pr", "review.finish"],
  "preview it": ["branch.preview", "review.preview", "forest.preview"],
  "sync it": ["branch.sync", "review.sync"],
  "the map": ["review.map", "tutor.map"],
  "show the type": ["review.types", "tutor.types"],
  "go to the definition": ["review.definition", "tutor.definition"],
  "go to the type's definition": ["review.type-definition", "tutor.type-definition"],
  "go to the implementations": ["review.implementation", "tutor.implementation"],
  "list the references": ["review.references", "tutor.references"],
  "list the file's symbols": ["review.symbols", "tutor.symbols"],
  "start writing": ["review.note.insert", "tutor.write", "branch.describe.edit"],
};

const KEY = /^(?:[CA]-)?(?:.|space|esc|ret|tab|up|down|left|right)$/u;
export const validKey = (k: string) => k.split(" ").every((t) => KEY.test(t));

/** Set each overridden command's keys; returns what couldn't be applied. */
export function applyKeys(cmds: Bound[], overrides: Record<string, string[]>): string[] {
  const problems: string[] = [];
  for (const [id, keys] of Object.entries(overrides)) {
    const c = cmds.find((x) => x.id === id);
    if (!c) {
      problems.push(`${id}: no such command`);
      continue;
    }
    const bad = keys.filter((k) => !validKey(k));
    if (bad.length) problems.push(`${id}: not a key — ${bad.map((k) => `"${k}"`).join(", ")}`);
    c.keys = keys.filter(validKey);
  }
  return problems;
}

/** Keys that mean different things on different pages, or two things in one place. */
export function clashes(cmds: Bound[]): string[] {
  const surfaces = Object.entries(SURFACE_SCOPES);
  const move = (id: string) => Object.keys(SAME_MOVE).find((k) => SAME_MOVE[k].includes(id)) ?? id;
  const scopeOf = new Map(cmds.map((c) => [c.id, c.scope]));
  const out: string[] = [];

  const byKey = new Map<string, Map<string, Set<string>>>();
  const inScope = new Map<string, string[]>();
  for (const c of cmds) {
    for (const key of c.keys ?? []) {
      const here = `${c.scope} ${key}`;
      inScope.set(here, [...(inScope.get(here) ?? []), c.id]);
      const pages = surfaces.filter(([, scopes]) => c.scope === "global" || scopes.includes(c.scope)).map(([s]) => s);
      if (!pages.length) out.push(`${c.id}: scope ${c.scope} is on no page`);
      const at = byKey.get(key) ?? new Map<string, Set<string>>();
      for (const p of pages) at.set(p, (at.get(p) ?? new Set()).add(c.id));
      byKey.set(key, at);
    }
  }
  for (const [here, ids] of inScope) if (ids.length > 1) out.push(`${here.split(" ").slice(1).join(" ")}: ${ids.join(" and ")} in one place`);

  for (const [key, at] of byKey) {
    // a page's own command wins over a global one, so the global meaning counts only where a page has none
    const meaning = new Map<string, string>();
    for (const [page, ids] of at) {
      const own = [...ids].filter((id) => scopeOf.get(id) !== "global");
      meaning.set(page, [...new Set((own.length ? own : [...ids]).map(move))].sort().join(" | "));
    }
    if (new Set(meaning.values()).size > 1) out.push(`${key}: ${[...meaning].map(([p, m]) => `${p} → ${m}`).join(", ")}`);
  }
  return out;
}
