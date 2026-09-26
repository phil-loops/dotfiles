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
