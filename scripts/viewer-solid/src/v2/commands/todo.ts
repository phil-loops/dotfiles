// The tracker: open an item, start it, finish or drop it, reorder the queue (POST /todo-item).
// Ranking the whole queue and writing next steps is /next's job, through canopy-todo.
import { model, tkey } from "../model";
import { command, type Write } from "../registry";
import { list, view, world } from "../store";
import { rerank, sectionOf } from "../tracker";
import type { TodoItem } from "../types";
import { setCursor, setTodoOpen, toggleIn } from "../ui";

type State = TodoItem["state"];
const exists = (id: string | undefined) => !!id && !!view("todo", id);

function moveTo(state: State, said?: (t: TodoItem) => string) {
  return (id: string): Write | null => {
    const t = view("todo", id);
    if (!t || t.state === state) return null;
    const closing = state === "done" || state === "dropped";
    return {
      ops: [{ type: "todo", id, fields: closing ? { state, rank: undefined } : { state } }],
      path: "/todo-item",
      body: { id, set: { state } },
      settled: () => world.entities.todo[id]?.state === state,
      said: said?.(t),
      failed: `couldn't mark ${t.title} ${state}`,
      inverse: { id: "todo.state", target: id, arg: { state: t.state, rank: t.rank ?? null } },
    };
  };
}

command({
  id: "todo.open",
  title: "Show or hide the item's notes",
  scope: "item",
  budget: "local",
  keys: ["ret"],
  available: exists,
  local: (id) => setTodoOpen((s) => toggleIn(s, id!)),
});
command({
  id: "todo.start",
  title: "Start it (doing)",
  scope: "item",
  budget: "config-write",
  keys: ["I"],
  available: (id) => exists(id) && view("todo", id!)!.state === "open",
  write: moveTo("doing"),
});
command({
  id: "todo.done",
  title: "Mark it done",
  scope: "item",
  budget: "config-write",
  keys: ["D"],
  available: (id) => exists(id) && !["done", "dropped", "broken"].includes(view("todo", id!)!.state),
  write: moveTo("done", (t) => `done: ${t.title} — u puts it back`),
});
command({
  id: "todo.drop",
  title: "Drop it",
  scope: "item",
  budget: "config-write",
  keys: ["X"],
  available: (id) => exists(id) && !["done", "dropped", "broken"].includes(view("todo", id!)!.state),
  write: moveTo("dropped", (t) => `dropped: ${t.title} — u puts it back`),
});
command({
  id: "todo.state",
  title: "Put an item back as it was",
  scope: "item",
  budget: "config-write",
  quiet: true,
  write: (id, arg) => {
    const { state, rank } = arg as { state: State; rank: number | null };
    const t = view("todo", id);
    if (!t) return null;
    return {
      ops: [{ type: "todo", id, fields: { state, rank: rank ?? undefined } }],
      path: "/todo-item",
      body: { id, set: { state, ...(rank != null ? { rank } : {}) } },
      settled: () => world.entities.todo[id]?.state === state,
      said: `back: ${t.title}`,
      failed: `couldn't put ${t.title} back`,
    };
  },
});

// ── the queue's order ──

function ranksWrite(id: string, ranks: Record<string, number | null>, failed: string, inverse?: Write["inverse"]): Write {
  setCursor(tkey(id));
  return {
    ops: Object.entries(ranks).map(([i, r]) => ({ type: "todo" as const, id: i, fields: { rank: r ?? undefined } })),
    path: "/todo-item",
    body: { ranks },
    settled: () => Object.entries(ranks).every(([i, r]) => (world.entities.todo[i]?.rank ?? null) === r),
    failed,
    inverse,
  };
}

function move(id: string, by: number): Write | null {
  const items = list("todo");
  const me = view("todo", id);
  const section = me && sectionOf(me);
  if (!section) return null;
  const at = model.todos().find((s) => s.section === section)!.items.findIndex((t) => t.id === id);
  const ranks = rerank(items, id, at + by);
  if (!ranks) return null;
  const before = Object.fromEntries(Object.keys(ranks).map((i) => [i, view("todo", i)?.rank ?? null]));
  return ranksWrite(id, ranks, `couldn't move ${me.title}`, { id: "todo.ranks", target: id, arg: before });
}

const movable = (id: string | undefined) => exists(id) && !!sectionOf(view("todo", id!)!) && view("todo", id!)!.state !== "broken";
command({ id: "todo.up", title: "Move up the queue", scope: "item", budget: "config-write", keys: ["C-k"], available: movable, write: (id) => move(id, -1) });
command({ id: "todo.down", title: "Move down the queue", scope: "item", budget: "config-write", keys: ["C-j"], available: movable, write: (id) => move(id, 1) });
command({
  id: "todo.ranks",
  title: "Put the queue's order back",
  scope: "item",
  budget: "config-write",
  quiet: true,
  write: (id, arg) => ranksWrite(id, arg as Record<string, number | null>, "couldn't put the order back"),
});
