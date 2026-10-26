// What the space menu finds besides commands: branches and forests by fuzzy name, a branch by its PR
// number. Each result is a quiet command plus its argument, so opening one runs through the runner.
import type { Branch, Pr, Project } from "./types";

export interface Find {
  cmd: "find.branch" | "find.forest";
  id: string;
  title: string;
  sub: string;
}

const LIMIT = 30;

/** Substring outranks subsequence; consecutive runs and word-start hits rank tighter (v1's ⌘K). */
export function fuzzyScore(needle: string, hay: string): number {
  const at = hay.indexOf(needle);
  if (at !== -1) return 1e6 - at * 10 - hay.length;
  let score = 0;
  let prev = -2;
  for (const ch of needle) {
    const j = hay.indexOf(ch, prev + 1);
    if (j === -1) return -Infinity;
    score += j === prev + 1 ? 10 : 1;
    if (j === 0 || "-/ _.".includes(hay[j - 1])) score += 5;
    prev = j;
  }
  return score - hay.length * 0.01;
}

/** The branches and forests matching what's typed, best first; an archived forest's sink to the end. */
export function finds(q: string, w: { branches: Branch[]; projects: Project[]; prs: Pr[] }): Find[] {
  const needle = q.toLowerCase().replace(/\s+/g, "");
  if (!needle) return [];
  const projects = new Map(w.projects.map((p) => [p.id, p]));
  const prOf = new Map(w.prs.map((r) => [r.id, r.number]));
  const number = /^#?(\d+)$/.exec(needle)?.[1];
  const scored: { f: Find; s: number; archived: boolean }[] = [];
  for (const p of w.projects) {
    const s = fuzzyScore(needle, p.name.toLowerCase());
    if (s > -Infinity) scored.push({ f: { cmd: "find.forest", id: p.id, title: p.name, sub: "forest" }, s: s + 1, archived: p.state === "archive" });
  }
  for (const b of w.branches) {
    const pr = prOf.get(b.id);
    const s = number ? (pr !== undefined && String(pr) === number ? 2e6 : -Infinity) : fuzzyScore(needle, b.name.toLowerCase());
    if (s === -Infinity) continue;
    const project = projects.get(b.project);
    const sub = [pr !== undefined ? `#${pr}` : "", project?.name ?? ""].filter(Boolean).join(" · ");
    scored.push({ f: { cmd: "find.branch", id: b.id, title: b.name, sub }, s, archived: project?.state === "archive" });
  }
  return scored
    .sort((a, b) => Number(a.archived) - Number(b.archived) || b.s - a.s)
    .slice(0, LIMIT)
    .map((x) => x.f);
}
