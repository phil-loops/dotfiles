import type { Commit } from "./types";

/** The branch's own commits oldest-first — the order its outline reads in. */
export function outlineOf(commits: Commit[] | undefined): Commit[] {
  return (commits ?? []).filter((c) => c.own !== false).reverse();
}

/** 1-based position among the branch's own non-carried commits, or undefined. */
export function outlineNumber(outline: Commit[], sha: string): number | undefined {
  const mine = outline.filter((c) => !c.carried);
  const i = mine.findIndex((c) => c.sha === sha);
  return i === -1 ? undefined : i + 1;
}

/** The contiguous run of outline commits between two shas, oldest first; [] unless both are in the outline. */
export function sliceOf(outline: Commit[], a: string, b: string): Commit[] {
  const i = outline.findIndex((c) => c.sha === a);
  const j = outline.findIndex((c) => c.sha === b);
  if (i === -1 || j === -1) return [];
  return outline.slice(Math.min(i, j), Math.max(i, j) + 1);
}

/** The commits a push would send — everything from the first unpushed one; [] when origin is current or absent. */
export function outgoingOf(outline: Commit[]): Commit[] {
  if (!outline.some((c) => c.pushed !== undefined)) return [];
  const f = outline.findIndex((c) => c.pushed === false);
  return f === -1 ? [] : outline.slice(f);
}
