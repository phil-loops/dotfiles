import { test } from "node:test";
import assert from "node:assert/strict";
import { applyPatchTo, checkVersion, emptyEntities } from "./patch.ts";

test("versions advance by exactly one per domain", () => {
  const v = { git: 3, remote: 7, review: 0, todo: 0 };
  assert.equal(checkVersion(v, { domain: "git", version: 4, upserts: {}, deletes: {} }), "ok");
  assert.equal(checkVersion(v, { domain: "git", version: 3, upserts: {}, deletes: {} }), "stale");
  assert.equal(checkVersion(v, { domain: "git", version: 6, upserts: {}, deletes: {} }), "gap");
  assert.equal(checkVersion(v, { domain: "remote", version: 8, upserts: {}, deletes: {} }), "ok");
});

test("a patch deletes then upserts, by type and id", () => {
  const e = emptyEntities();
  (e.branch as Record<string, unknown>)["r:a"] = { id: "r:a" };
  (e.branch as Record<string, unknown>)["r:b"] = { id: "r:b" };
  applyPatchTo(e, {
    domain: "git",
    version: 1,
    upserts: { project: { "r:p": { id: "r:p", state: "archive" } }, branch: { "r:b": { id: "r:b", v: 2 } } },
    deletes: { branch: ["r:a"] },
  });
  assert.deepEqual(Object.keys(e.branch), ["r:b"]);
  assert.deepEqual(e.branch["r:b"] as unknown, { id: "r:b", v: 2 });
  assert.equal((e.project["r:p"] as unknown as { state: string }).state, "archive");
});

test("a patch reaches every entity type the store holds", () => {
  const ents = emptyEntities();
  const upserts = Object.fromEntries(Object.keys(ents).map((t) => [t, { x: { id: "x" } }]));
  applyPatchTo(ents, { domain: "git", version: 1, upserts, deletes: {} });
  for (const [t, table] of Object.entries(ents)) assert.ok("x" in table, `${t} dropped the patch`);
});
