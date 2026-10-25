import { test } from "node:test";
import assert from "node:assert/strict";
import { queue, rerank } from "./tracker.ts";
import type { TodoItem } from "./types.ts";

const t = (id: string, f: Partial<TodoItem> = {}): TodoItem => ({ id, title: id, kind: "build", state: "open", area: "x", size: "S", why: "", body: "", ...f });

test("needs-you first, then doing, the ranked queue, and waiting; done and dropped are gone", () => {
  const items = [
    t("later", { created: "2026-10-02" }),
    t("first", { rank: 1 }),
    t("call", { kind: "decide" }),
    t("busy", { state: "doing" }),
    t("hankles", { state: "waiting", waiting: "next review" }),
    t("old", { state: "done" }),
    t("earlier", { created: "2026-10-01" }),
  ];
  assert.deepEqual(
    queue(items).map((s) => `${s.section}: ${s.items.map((x) => x.id).join(" ")}`),
    ["decide: call", "doing: busy", "next: first earlier later", "waiting: hankles"],
  );
});

test("moving an item keeps the section's rank numbers and numbers the unranked after all ranks", () => {
  const items = [t("a", { rank: 2 }), t("b", { rank: 5 }), t("c", { created: "1" }), t("call", { kind: "decide", rank: 9 })];
  assert.deepEqual(rerank(items, "c", 0), { c: 2, a: 5, b: 10 });
  assert.deepEqual(rerank(items, "a", 1), { b: 2, a: 5 });
  assert.equal(rerank(items, "a", 0), null);
});
