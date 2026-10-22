// Helix-style key handling: single keys, `space` for the command menu, and chords written as
// space-separated sequences ("g d"). Pure, so it's tested without a DOM.
export interface Binding {
  id: string;
  keys: string[];
  scope: string;
}

/** A KeyboardEvent as a key name: "x", "G", "?", "space", "esc", "ret", "down", "C-k". */
export function keyName(e: { key: string; ctrlKey?: boolean; metaKey?: boolean; altKey?: boolean }): string | null {
  const named: Record<string, string> = { " ": "space", Escape: "esc", Enter: "ret", ArrowDown: "down", ArrowUp: "up", ArrowLeft: "left", ArrowRight: "right", Tab: "tab" };
  const k = named[e.key] ?? (e.key.length === 1 ? e.key : null);
  if (!k) return null;
  if (e.metaKey) return null;
  return e.ctrlKey ? `C-${k}` : e.altKey ? `A-${k}` : k;
}

export type Fed = { kind: "run"; id: string } | { kind: "pending"; prefix: string } | { kind: "none" };

/** Feed keys one at a time; `scopes` is the active scopes, narrowest first (it breaks ties). */
export function createKeymap(bindings: Binding[]) {
  let buf: string[] = [];
  return {
    feed(key: string, scopes: string[]): Fed {
      buf.push(key);
      const seq = buf.join(" ");
      const live = bindings.filter((b) => scopes.includes(b.scope));
      const hits = live.filter((b) => b.keys.includes(seq));
      if (hits.length) {
        buf = [];
        hits.sort((a, b) => scopes.indexOf(a.scope) - scopes.indexOf(b.scope));
        return { kind: "run", id: hits[0].id };
      }
      if (live.some((b) => b.keys.some((k) => k.startsWith(seq + " ")))) return { kind: "pending", prefix: seq };
      buf = [];
      return { kind: "none" };
    },
    reset() {
      buf = [];
    },
  };
}
