import { test } from "node:test";
import assert from "node:assert/strict";
import { bare, bodyHints, hasPlan, hintsFor, joinTemplate, prefixOf, splitTemplate, stripPlan, withScope } from "./outlineHints.ts";

const ids = (h: { id: string }[]) => h.map((x) => x.id);

test("prefixOf reads type, scope and bang", () => {
  assert.deepEqual(prefixOf("feat(LOO-1)!: add it"), { type: "feat", scope: "LOO-1", bang: "!", rest: "add it" });
  assert.equal(prefixOf("complaints -> spamReports"), undefined);
  assert.equal(prefixOf("note: not a type"), undefined);
});

test("withScope normalizes the scope to the ticket and adds a prefix when missing", () => {
  assert.equal(withScope("feat(LOO-6222): find messages", "loo-6222"), "feat(loo-6222): find messages");
  assert.equal(withScope("fix: stop flicker", "loo-1"), "fix(loo-1): stop flicker");
  assert.equal(withScope("stop flicker", "loo-1"), "feat(loo-1): stop flicker");
});

test("a clean opening commit has no hints", () => {
  assert.deepEqual(hintsFor({ subject: "feat(loo-9): add widget queries", body: "" }, { opening: true, ticket: "loo-9" }), []);
});

test("the opening commit wants the ticket scope, lowercase", () => {
  const h = hintsFor({ subject: "feat(LOO-9): add widget queries", body: "" }, { opening: true, ticket: "loo-9" });
  assert.deepEqual(ids(h), ["scope"]);
  assert.equal(h[0].fix!.apply({ subject: "feat(LOO-9): add widget queries", body: "" }).subject, "feat(loo-9): add widget queries");
});

test("follow-ups read bare", () => {
  const h = hintsFor({ subject: "refactor: extract the widget card", body: "" }, { opening: false, ticket: "loo-9" });
  assert.deepEqual(ids(h), ["bare"]);
  assert.equal(bare("refactor(x): extract the widget card"), "extract the widget card");
});

test("length is the words after type(scope): — Phil's own titles pass, drafted ones don't", () => {
  for (const s of ["feat(LOO-6208): Unlock goal window", "fix(loo-6120): render critical notice", "feat(loo-6219): drop legacy admin interaction stuff", "fix(LOO-5990): Allowlist the campaign update body"]) {
    assert.ok(!ids(hintsFor({ subject: s, body: "" }, { opening: true, ticket: s.match(/\((.*?)\)/)![1] })).includes("long"), s);
  }
  assert.ok(ids(hintsFor({ subject: "fix(loo-6229): migrate the disable domain function to always leave breadcrumbs", body: "" }, { opening: true, ticket: "loo-6229" })).includes("long"));
});

test("long subjects and placeholders are flagged", () => {
  const h = hintsFor({ subject: "wip " + "x".repeat(60), body: "" }, { opening: false });
  assert.deepEqual(ids(h), ["wip", "long"]);
});

test("a baked forest block is detected and stripped, prose kept", () => {
  const body = "Part of a stack (demo):\n\n1. demo/queries — adds the widget queries  ← this branch\n2. demo/model — moves rules\n\nThe query layer stays thin.";
  assert.ok(hasPlan(body));
  assert.equal(stripPlan(body), "The query layer stays thin.");
  assert.equal(stripPlan("why it matters\n\nPart of a stack, in merge order:\n  1. [this branch]\n  2. #123"), "why it matters");
  assert.equal(stripPlan("prose\n-- forest --\nPart of x, 1 of 2."), "prose");
  // GitHub wraps a squash message at ~72 columns, so a long step continues on an unindented line
  const wrapped = "the why\n\nPart of a stack, in merge order:\n  1. #11090\n  2. [this branch]\n3. disable a team's domains in a transaction that records\nan event for each one it turns off\n4. record a disable event wherever an admin or a health check disables a\nsingle domain\n\n---\nTraffic Cop";
  assert.equal(stripPlan(wrapped), "the why\n\n---\nTraffic Cop");
  const h = hintsFor({ subject: "feat(loo-9): add", body }, { opening: true, ticket: "loo-9" });
  assert.deepEqual(ids(h), ["plan"]);
});

test("the PR title follows the opening rule but ignores bodies", () => {
  const h = hintsFor({ subject: "show widgets", body: "Part of a stack" }, { opening: true, ticket: "loo-9", kind: "title" });
  assert.deepEqual(ids(h), ["scope"]);
});

test("a PR body: the plan block is flagged, long prose noted, the template not counted", () => {
  const tpl = "---\n👮 Traffic Cop\n\n- [ ] tested";
  assert.deepEqual(bodyHints("👋 fare thee well\n\n" + tpl, tpl), []);
  assert.deepEqual(bodyHints("why\n\nPart of a stack, in merge order:\n  1. #1\n\n" + tpl, tpl).map((h) => h.id), ["plan"]);
  assert.deepEqual(bodyHints("x".repeat(300) + "\n\n" + tpl, tpl).map((h) => h.id), ["prose"]);
});

test("a PR body splits into Phil's lines and the template from its first rule, and rejoins", () => {
  const tpl = "---\n👮 Traffic Cop\n\n- [ ] Tested in staging";
  assert.deepEqual(splitTemplate(`why it matters\n\n${tpl}`), { own: "why it matters", template: tpl });
  assert.deepEqual(splitTemplate(`\n${tpl}`), { own: "", template: tpl });
  assert.deepEqual(splitTemplate("just a why"), { own: "just a why", template: "" });
  assert.equal(joinTemplate("new why", tpl), `new why\n\n${tpl}`);
  assert.equal(joinTemplate("", tpl), tpl);
});
