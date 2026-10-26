import { test } from "node:test";
import assert from "node:assert/strict";
import { finds } from "./find.ts";
import type { Branch, Pr, Project } from "./types.ts";

const p = (name: string, f: Partial<Project> = {}): Project => ({ id: `loops:${name}`, repo: "loops", name, state: "workbench", rank: null, ticket: null, summary: "", size: 1, ...f });
const b = (name: string, project: string): Branch => ({ id: `loops:${name}`, repo: "loops", name, project: `loops:${project}` }) as Branch;
const pr = (branch: string, number: number): Pr => ({ id: `loops:${branch}`, repo: "loops", branch, number }) as Pr;

const world = {
  projects: [p("dep-cleanup"), p("old-thing", { state: "archive" })],
  branches: [
    b("dep-cleanup/remove-unused-deps", "dep-cleanup"),
    b("dep-cleanup/remove-unused-lint-directives", "dep-cleanup"),
    b("old-thing/unused", "old-thing"),
  ],
  prs: [pr("dep-cleanup/remove-unused-deps", 11130)],
};
const ids = (q: string) => finds(q, world).map((f) => `${f.cmd}:${f.id}`);

test("nothing typed finds nothing — the menu is commands until you type", () => {
  assert.deepEqual(ids(""), []);
  assert.deepEqual(ids("  "), []);
});

test("letters in order find a branch by name, word starts and runs ranking tighter", () => {
  assert.deepEqual(ids("rmunusdeps"), ["find.branch:loops:dep-cleanup/remove-unused-deps"]);
  assert.deepEqual(ids("unused lint"), ["find.branch:loops:dep-cleanup/remove-unused-lint-directives"]);
  assert.deepEqual(ids("zzz"), []);
});

test("a substring beats a scatter; archived forests' branches come last", () => {
  assert.deepEqual(ids("unused"), [
    "find.branch:loops:dep-cleanup/remove-unused-deps",
    "find.branch:loops:dep-cleanup/remove-unused-lint-directives",
    "find.branch:loops:old-thing/unused",
  ]);
});

test("a forest's name finds the forest above its branches", () => {
  assert.deepEqual(ids("dep-cleanup")[0], "find.forest:loops:dep-cleanup");
});

test("a PR number, with or without #, finds its branch", () => {
  assert.deepEqual(ids("11130"), ["find.branch:loops:dep-cleanup/remove-unused-deps"]);
  assert.deepEqual(ids("#11130"), ["find.branch:loops:dep-cleanup/remove-unused-deps"]);
});

test("a branch row says its PR and forest", () => {
  const [f] = finds("11130", world);
  assert.equal(f.title, "dep-cleanup/remove-unused-deps");
  assert.equal(f.sub, "#11130 · dep-cleanup");
});
