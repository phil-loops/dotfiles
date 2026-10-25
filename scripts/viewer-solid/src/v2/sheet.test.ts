import { test } from "node:test";
import assert from "node:assert/strict";
import { sheetNow, type SheetCmd } from "./sheet.ts";

const c = (id: string, scope: string, keys: string[], available = true): SheetCmd => ({ id, title: id, scope, keys, available });
const keys = (ls: { key: string; cmd: SheetCmd }[]) => ls.map((l) => `${l.key}=${l.cmd.id}`).join(" ");

test("now: what the cursor's thing can do, narrowest first; a shadowed key shows as what it runs", () => {
  const cmds = [
    c("forest.expand", "project", ["l", "right"]),
    c("branch.open", "branch", ["l", "right"]),
    c("branch.push", "branch", ["p"], false),
    c("project.archive", "project", ["X"]),
    c("ready.toggle", "forests", ["F"]),
    c("cursor.down", "global", ["j", "down"]),
    c("review.reply", "thread", ["r"]),
  ];
  const s = sheetNow("forests", ["branch", "project", "row", "forests", "global"], cmds);
  assert.equal(keys(s.now), "l · right=branch.open X=project.archive F=ready.toggle");
  assert.equal(keys(s.everywhere), "j · down=cursor.down");
  assert.equal(keys(s.notNow), "l · right=forest.expand p=branch.push");
});

test("with nothing under the cursor, the item keys wait in not-now", () => {
  const cmds = [c("todo.done", "item", ["D"]), c("nav.forests", "global", ["g f"])];
  const s = sheetNow("todo", ["todo", "global"], cmds);
  assert.equal(keys(s.now), "");
  assert.equal(keys(s.everywhere), "g f=nav.forests");
  assert.equal(keys(s.notNow), "D=todo.done");
});
