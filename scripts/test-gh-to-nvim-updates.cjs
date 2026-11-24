const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "gh-to-nvim/background.js"), "utf8");
const idle = () => new Promise(setImmediate);

function start(fixture, development = false) {
  const event = { addListener() {} };
  let updated;
  const chrome = {
    tabs: { onUpdated: event, onActivated: event },
    commands: { onCommand: event, getAll: async () => [{ name: "open-in-nvim", shortcut: "Cmd+Shift+O" }] },
    management: { getSelf: async () => ({ installType: development ? "development" : "admin" }) },
    storage: { session: {
      get: async key => ({ [key]: fixture.session[key] }),
      set: async data => Object.assign(fixture.session, data),
    } },
    runtime: {
      id: "test", getManifest: () => ({ version: "0.3.9" }),
      onUpdateAvailable: { addListener(fn) { updated = fn } }, onInstalled: event, onMessage: event,
      async requestUpdateCheck() { fixture.checks++; return { status: fixture.result }; },
      reload() { fixture.reloads++; },
    },
    alarms: { create() {}, onAlarm: event },
    action: { setIcon() {}, setTitle() {}, setBadgeText() {}, setBadgeBackgroundColor() {} },
  };
  const ctx = vm.createContext({ chrome, importScripts() {}, setInterval() {}, Date: { now: () => fixture.now },
    VIEWER_URL: "http://fixture", fetch: async () => ({ ok: true, json: async () => fixture.server }) });
  vm.runInContext(source, ctx);
  return { poll: () => vm.runInContext("poll()", ctx), downloaded: () => updated() };
}

function fixture() {
  return { now: 100000, result: "throttled", checks: 0, reloads: 0, session: {},
    server: { mtime: 1, published: { test: "0.3.9" } } };
}

test("only a newer published package for this install triggers a check", async () => {
  const f = fixture(), worker = start(f);
  await idle();
  for (const published of [{}, { other: "0.4" }, { test: "0.3.8" }, { test: "0.3.9.0" }]) {
    f.server = { mtime: f.server.mtime + 1, published };
    await worker.poll();
    assert.equal(f.checks, 0);
  }
  f.server.published.test = "0.3.10";
  await Promise.all([worker.poll(), worker.poll()]);
  assert.equal(f.checks, 1);
  assert.equal(f.session.state, "updating");
  const nextWorker = start(f);
  await idle();
  assert.equal(f.checks, 1);
  f.now += 60 * 60_000;
  f.result = "update_available";
  await nextWorker.poll();
  assert.equal(f.checks, 2);
  assert.equal(f.reloads, 0);
  nextWorker.downloaded();
  assert.equal(f.reloads, 1);
});

test("a packed copy detects an older install even on its first poll", async () => {
  const f = fixture();
  f.server.published.test = "0.4";
  start(f);
  await idle();
  assert.equal(f.checks, 1);
});

test("unpacked changes reload after settling without an update check", async () => {
  const f = fixture(), worker = start(f, true);
  await idle();
  f.server = { mtime: 2, published: { test: "0.4" } };
  await worker.poll();
  assert.equal(f.reloads, 0);
  f.now += 1500;
  await worker.poll();
  assert.equal(f.reloads, 1);
  assert.equal(f.checks, 0);
});
