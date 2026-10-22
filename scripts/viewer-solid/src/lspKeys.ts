// Helix's type keys on the branch page: K and space·k hover, g·d goes to the definition.
// A leader (space, g) arms for one key; anything else drops it and falls through untouched.

export type Leader = "" | "space" | "g";
export type LspAction = "hover" | "definition";

/** The next leader and the action (if any) for a key, given the armed leader. `consumed` = swallow the key. */
export function chord(leader: Leader, key: string): { leader: Leader; action: LspAction | null; consumed: boolean } {
  if (leader === "space" && key === "k") return { leader: "", action: "hover", consumed: true };
  if (leader === "g" && key === "d") return { leader: "", action: "definition", consumed: true };
  if (key === "K") return { leader: "", action: "hover", consumed: true };
  if (key === " ") return { leader: "space", action: null, consumed: true };
  if (key === "g") return { leader: "g", action: null, consumed: true };
  return { leader: "", action: null, consumed: false };
}

/** The identifier around a UTF-16 offset in a line: a caret just past a word still means that word. */
export function wordAt(text: string, offset: number): { start: number; end: number } | null {
  const isWord = (i: number) => i >= 0 && i < text.length && /[\w$]/.test(text[i]);
  let at = offset;
  if (!isWord(at)) {
    if (!isWord(at - 1)) return null;
    at -= 1;
  }
  let start = at, end = at + 1;
  while (isWord(start - 1)) start--;
  while (isWord(end)) end++;
  return { start, end };
}

/**
 * Which side of the diff a code cell shows. diff2html marks a removed line `d2h-del`, a kept one
 * `d2h-cntx`, an added one `d2h-ins`; side-by-side splits them into an old (0) and a new (1) table.
 * "new" lines exist at the branch tip; "old" ones only in the parent; "twin" is a kept line read
 * on the old side-by-side half, whose tip line number sits on the same row of the new half;
 * "none" is a hunk header or the blank filler beside a one-sided change.
 */
export function sideOf(cellClasses: string[], sbsIndex: number | null): "new" | "old" | "twin" | "none" {
  const has = (c: string) => cellClasses.includes(c);
  if (has("d2h-info") || has("d2h-emptyplaceholder")) return "none";
  if (has("d2h-del")) return "old";
  if (has("d2h-ins")) return "new";
  if (has("d2h-cntx")) return sbsIndex === 0 ? "twin" : "new";
  return "none";
}
