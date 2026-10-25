import { test } from "node:test";
import assert from "node:assert/strict";
import { sheetSections } from "./sheet.ts";

const order = (s: { scope: string; live: boolean }[]) => s.map((x) => `${x.scope}${x.live ? "*" : ""}`).join(" ");

test("on a review thread, the thread's keys come first and Forests' keys are gone", () => {
  assert.equal(order(sheetSections("review", ["thread", "review", "global"])), "thread* review* pending line global*");
});

test("on Forests with a branch selected, branch then forest then row", () => {
  assert.equal(order(sheetSections("forests", ["branch", "project", "row", "forests", "global"])), "branch* project* row* forests* global*");
});

test("the dashboard shows only its own keys and everywhere", () => {
  assert.equal(order(sheetSections("dashboard", ["dashboard", "global"])), "dashboard* global*");
});
