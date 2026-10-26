// The hint line: the few keys that act on what the cursor is on right now, pinned to the bottom of
// every page so they're learnt by seeing them. Built from the registry like `?`'s "Right now"; a
// key fades out once it's been pressed enough times to be known. Uses are counted per viewer, in
// localStorage (a convenience: losing it just brings the hints back).
import { createSignal } from "solid-js";

const KEY = "v2.keyuse";
/** pressed this many times by key, a command's hint has done its job */
export const KNOWN_AFTER = 12;

const read = (): Record<string, number> => {
  try {
    return JSON.parse(localStorage.getItem(KEY) || "{}");
  } catch {
    return {};
  }
};
const [uses, setUses] = createSignal<Record<string, number>>(read());

/** The runner calls this for every command run from a key. */
export function noteKeyUse(id: string): void {
  const next = { ...uses(), [id]: (uses()[id] ?? 0) + 1 };
  setUses(next);
  try {
    localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    /* private window: per-load only */
  }
}

export const known = (id: string) => (uses()[id] ?? 0) >= KNOWN_AFTER;

/** A title as a hint: its first clause, lowercase — "Mark viewed — the hunk…" reads "mark viewed". */
export const short = (title: string) => {
  const t = title.split(/ — | \(|, or /)[0].trim();
  return t.charAt(0).toLowerCase() + t.slice(1);
};
