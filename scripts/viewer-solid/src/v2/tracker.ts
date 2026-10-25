// The tracker page's order: what needs Phil, what's under way, the ranked queue, what waits on
// something else. Pure, so the page, the cursor and reordering agree and it's tested without a DOM.
import type { TodoItem } from "./types";

export type Section = "broken" | "decide" | "doing" | "next" | "waiting";
export const SECTION_TITLES: Record<Section, string> = {
  broken: "Can't read",
  decide: "Needs you",
  doing: "Doing",
  next: "Next",
  waiting: "Waiting",
};
const ORDER: Section[] = ["broken", "decide", "doing", "next", "waiting"];

export function sectionOf(t: TodoItem): Section | null {
  if (t.state === "broken") return "broken";
  if (t.state === "done" || t.state === "dropped") return null;
  if (t.state === "waiting") return "waiting";
  if (t.kind === "decide") return "decide";
  return t.state === "doing" ? "doing" : "next";
}

const byQueue = (a: TodoItem, b: TodoItem) =>
  (a.rank ?? Infinity) - (b.rank ?? Infinity) || (a.created ?? "").localeCompare(b.created ?? "") || a.id.localeCompare(b.id);

/** Open items by section, each in rank order (unranked after, oldest first); empty sections left out. */
export function queue(items: TodoItem[]): { section: Section; items: TodoItem[] }[] {
  return ORDER.map((section) => ({ section, items: items.filter((t) => sectionOf(t) === section).sort(byQueue) })).filter((s) => s.items.length);
}

/** New ranks for moving `id` to position `to` within its section. The section keeps the rank
 *  numbers it already holds, so its place among /next's global ranking doesn't move; unranked
 *  items now ahead of a ranked one get numbers after every rank in use, those below stay unranked.
 *  Null when nothing moves. */
export function rerank(items: TodoItem[], id: string, to: number): Record<string, number> | null {
  const me = items.find((t) => t.id === id);
  const section = me && sectionOf(me);
  if (!section) return null;
  const order = items.filter((t) => sectionOf(t) === section).sort(byQueue);
  const from = order.findIndex((t) => t.id === id);
  to = Math.max(0, Math.min(order.length - 1, to));
  if (from === to) return null;
  order.splice(to, 0, ...order.splice(from, 1));
  const held = order.map((t) => t.rank).filter((r): r is number => r != null).sort((a, b) => a - b);
  let next = Math.max(0, ...items.map((t) => t.rank ?? 0));
  const last = Math.max(to, order.findLastIndex((t) => t.rank != null));
  const out: Record<string, number> = {};
  order.slice(0, last + 1).forEach((t, i) => {
    const r = held[i] ?? ++next;
    if (t.rank !== r) out[t.id] = r;
  });
  return out;
}
