// The picker's filter, as Helix's: every typed character in order, best matches first. Pure.

/** How well `text` matches `want` — lower is better, null when it doesn't. A run of the typed
 *  characters beats the same characters scattered, and an earlier start beats a later one. */
export function score(text: string, want: string): number | null {
  const w = want.replace(/\s+/g, "");
  if (!w) return 0;
  const run = text.indexOf(w);
  if (run >= 0) return run;
  let at = 0;
  let first = -1;
  for (const c of w) {
    at = text.indexOf(c, at);
    if (at < 0) return null;
    if (first < 0) first = at;
    at++;
  }
  return 1000 + (at - first) * 10 + first;
}

/** The items matching `want`, best first; ties keep their order. */
export function ranked<T>(items: T[], want: string, textOf: (t: T) => string): T[] {
  const f = want.toLowerCase();
  if (!f.trim()) return items;
  return items
    .map((it, i) => ({ it, i, s: score(textOf(it).toLowerCase(), f) }))
    .filter((x): x is { it: T; i: number; s: number } => x.s != null)
    .sort((a, b) => a.s - b.s || a.i - b.i)
    .map((x) => x.it);
}
