importScripts("./config.js");   // VIEWER_URL — single source of truth (see config.js)

const HOST = "com.loops.gh_to_nvim";   // native host that launches the viewer (idempotent stack-review-serve)

// ── URL-only by design ──
// There is no content script and no github.com host access: a user gesture (keyboard command
// or popup button) grants activeTab just long enough to read the tab's URL, and the server's
// POST /open-url owns ALL parsing — PR vs blob vs commit, and resolving GitHub's
// #diff-<sha256(path)>R<n> selected-line hash against the branch's changed files.

// Nothing on the server side is bounded: ctx.run() shells git/gh with no timeout, so one stalled
// fetch or a contended index.lock pends the request thread — and a pending request is the one
// failure the recovery ladder below can't see (it reads status 0 and 504, never a hang). Un-timed,
// that surfaces as a "…" badge forever, which is indistinguishable from the chord not firing at
// all. Longer than the server's own worst case (a 20s-bounded Diffview) so it only ever means stuck.
const POST_TIMEOUT_MS = 30000;

function post(payload) {
  return fetch(`${VIEWER_URL}/open-url`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(POST_TIMEOUT_MS),
  })
    .then(async (r) => ({ status: r.status, body: await r.json().catch(() => null) }))
    .catch((err) => ({ status: 0, error: String(err), timedOut: err?.name === "TimeoutError" }));
}

function launchViewer() {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendNativeMessage(HOST, { action: "launch" }, (res) => {
        resolve(chrome.runtime.lastError ? { ok: false, err: chrome.runtime.lastError.message } : (res || { ok: false, err: "no response" }));
      });
    } catch (e) {
      resolve({ ok: false, err: String(e) });
    }
  });
}

// canopy is the viewer: the native host runs its launcher with the address, so the PR opens in the
// app at its line rather than in a tab. Without the host, the tab's /v2 page hands itself over.
function openCanopy(route) {
  return new Promise((resolve) => {
    const tab = () => chrome.tabs.create({ url: `${VIEWER_URL}${route}` });
    try {
      chrome.runtime.sendNativeMessage(HOST, { action: "canopy", route }, (res) => {
        if (chrome.runtime.lastError || !res?.ok) {
          tab();
          resolve(false);
        } else {
          resolve(true);
        }
      });
    } catch {
      tab();
      resolve(false);
    }
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForViewer(timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if ((await extensionStatus()) !== null) {
      return true;
    }
    await sleep(500);
  }
  return false;
}

// Toolbar feedback in place of the old in-page toast: badge stages while working, ✓/✗ result,
// plus a notification for failures/warnings (a badge alone is easy to miss on a wrong jump).
let feedbackUntil = 0;   // apply() leaves the badge alone until this passes

async function badge(text, color, holdMs) {
  feedbackUntil = Date.now() + holdMs;
  shown = null;   // force the next poll to repaint the state badge once the hold expires
  await chrome.action.setBadgeText({ text });
  await chrome.action.setBadgeBackgroundColor({ color });
}

function notify(text) {
  chrome.notifications.create({
    type: "basic",
    iconUrl: "icons/fresh-128.png",
    title: "GitHub → Show",
    message: text,
  });
}

// macOS can deny Chrome's alert helper its notification permission (it's a separate entry in
// System Settings), silently dropping every notify() — so a failure also opens the popup, the
// one surface the OS can't suppress. The popup renders lastError from session storage.
async function fail(text) {
  await chrome.storage.session.set({ lastError: { text, at: Date.now() } });
  await badge("✗", "#F85149", 10000);
  await chrome.action.setTitle({ title: `GitHub → Show — failed: ${text}` });
  notify(text.slice(0, 200));
  try {
    await chrome.action.openPopup();
  } catch {
    // no focused window / popup already open — badge + title still carry the error
  }
}

const reason = (res) => res?.body?.err || res?.error || `status ${res?.status}`;

// Self-healing open: dead viewer → native-host launch + wait + one retry; cold first open
// (504 — the worktree still warming) → brief wait + retry.
async function openWithRecovery(payload) {
  const waiting = setTimeout(() => badge("…", "#58A6FF", 30000), 150);
  let res = await post(payload).finally(() => clearTimeout(waiting));
  if (res.timedOut) {
    // A live-but-stuck viewer must not take the launch path — stack-review-serve would find the
    // port held, report success, and the retry would hang exactly as long all over again.
    return { status: 0, error: `viewer took the request but never answered (${POST_TIMEOUT_MS / 1000}s) — it's stuck on a git or gh call` };
  }
  if (res.status === 0) {
    await badge("⏻", "#58A6FF", 30000);
    const launched = await launchViewer();
    if (!launched.ok) {
      return { status: 0, error: `couldn't launch viewer — ${launched.err}` };
    }
    await badge("◷", "#58A6FF", 30000);
    if (!(await waitForViewer(15000))) {
      return { status: 0, error: "viewer didn't come up" };
    }
    res = await post(payload);
  }
  for (let i = 0; i < 2 && res.status === 504; i++) {
    await badge("↻", "#58A6FF", 30000);
    await sleep(1200 + i * 800);
    res = await post(payload);
  }
  return res;
}

let latestOpen = 0;

async function openActiveTab(target, commandTab) {
  const started = performance.now();
  const request = ++latestOpen;
  const url = commandTab?.url || (await chrome.tabs.query({ active: true, currentWindow: true }))[0]?.url || "";   // readable only because the gesture granted activeTab
  if (!url.startsWith("https://github.com/")) {
    await fail("not a GitHub page");
    return;
  }
  // A warm route opens in one hop. On a cold import, bring the current Canopy workspace forward.
  let focus;
  let focusTimer;
  if (target === "viewer" && PR_RE.test(url)) {
    focusTimer = setTimeout(() => {
      if (request === latestOpen) {
        focus = chrome.runtime.sendNativeMessage(HOST, { action: "focus-canopy" }).catch(() => {});
      }
    }, 150);
  }
  let res;
  try {
    res = await openWithRecovery({ url, open: target });
  } finally {
    clearTimeout(focusTimer);
  }
  await focus;
  if (request !== latestOpen) {
    return;
  }
  const ok = res.status === 200 && res.body?.ok;
  if (!ok) {
    await fail(String(reason(res)));
    return;
  }
  if (target === "viewer" && res.body.path) {
    const delivered = await openCanopy(res.body.path === "/" ? "/v2" : res.body.path);
    if (request !== latestOpen) return;
    if (delivered && PR_RE.test(url)) {
      await chrome.storage.session.set({ lastHandoffMs: Math.round(performance.now() - started) });
    }
  }
  // a success can still carry a warning — the stack-open stale/force-push backstop landed the
  // cursor at EOF because this checkout differs from GitHub; never let that be a silent wrong jump
  const warn = res.body.err && String(res.body.err).trim().replace(/^stack-open:\s*/, "");
  await badge(warn ? "⚠" : "✓", warn ? "#D29922" : "#3FB950", 4000);
  if (warn) {
    await chrome.storage.session.set({ lastError: { text: warn, at: Date.now(), warn: true } });
    notify(warn.slice(0, 200));
  }
}

chrome.commands.onCommand.addListener((cmd, tab) => {
  if (cmd === "open-in-nvim") {
    openActiveTab("viewer", tab);
  }
});

// ── prewarm ──
// The PR page you're LOOKING at is the best predictor of the next ⌘⇧O, so pay the cold cost
// (import the head, build the worktree — together ~1.4s, plus a fetch for someone else's PR)
// while you're still reading the diff, instead of at the instant you press the key.
//
// This is why the extension takes "tabs": it needs to know you landed on a PR without you
// pressing anything. That grants URL visibility across tabs and NOTHING else — no DOM, no
// injection, no fetching github.com as you (a github.com host grant would allow that, which is
// the worse trade while the signing key is public). Enforced below: the ONLY thing that ever
// leaves the browser is a URL matching PR_RE.
const PR_RE = /^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+/;
const recentPRs = new Map();
// The server trusts a prewarm's fetch for the next keypress (30 min), so the same PR warms again
// after a minute: a reload after the author pushes refetches, a line click inside the minute doesn't.
const PREWARM_REPEAT_MS = 60000;

let lastLaunchAt = 0;
const LAUNCH_COOLDOWN_MS = 60000;   // bound a host that can't start; one boot per idle-reap cycle

function prewarmPost(pr) {
  return fetch(`${VIEWER_URL}/open-url`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url: pr, open: "prewarm" }),
    signal: AbortSignal.timeout(POST_TIMEOUT_MS),
  }).then(() => true).catch(() => false);   // reached the server at all? a 4xx still counts
}

async function prewarm(url) {
  const m = (url || "").match(PR_RE);
  if (!m) return;
  const now = Date.now();
  for (const [pr, at] of recentPRs) {
    if (now - at >= PREWARM_REPEAT_MS) recentPRs.delete(pr);
  }
  if (recentPRs.has(m[0])) return;
  recentPRs.set(m[0], now);
  if (await prewarmPost(m[0])) {
    return;
  }
  // The viewer self-reaps after 15min idle, so the first PR of a session finds it gone and the
  // prewarm quietly does nothing — leaving the entire cold cost (boot, import, worktree: ~8s)
  // on the first ⌘⇧O. That is the press that "only launches the forest": it is working, it just
  // hasn't finished by the time a second press lands warm and takes the credit. Boot it here
  // instead, while the diff is still being read. No extra launches — once up it stays up, so
  // this is the same one-per-session boot, moved off the keypress.
  if (Date.now() - lastLaunchAt < LAUNCH_COOLDOWN_MS) {
    return;
  }
  lastLaunchAt = Date.now();
  if (!(await launchViewer()).ok || !(await waitForViewer(15000))) {
    return;   // the chord's recovery ladder is still the backstop
  }
  await prewarmPost(m[0]);
}

// GitHub is a Turbo app: clicking a PR out of the list, or the Files tab of the PR you're on, is
// a pushState navigation that fires onUpdated with a URL and NO status — so gating on
// status:"complete" warmed only the PRs you reached by a full page load, missing the way you
// usually get there. The PR-keyed dedupe above is what makes the wider trigger free.
chrome.tabs.onUpdated.addListener((_id, info, tab) => {
  if (info.status === "complete" || info.url) {
    prewarm(tab?.url);
  }
});

chrome.tabs.onActivated.addListener(({ tabId }) => {
  chrome.tabs.get(tabId).then(tab => prewarm(tab.url), () => {});
});

// The popup's open button routes here — opening the popup is itself the
// activeTab gesture, so the tab URL is readable for the click that follows.
chrome.runtime.onMessage.addListener((msg, _s, respond) => {
  if (msg?.type === "open-canopy") {
    openCanopy(msg.route || "/v2").then(() => respond({ ok: true }));
    return true;
  }
  if (msg?.type !== "open-url") {
    return;
  }
  openActiveTab(msg.target || "viewer").then(() => respond({ ok: true }));
  return true;
});

const ICONS = {
  fresh: iconSet("fresh"),
  stale: iconSet("stale"),
  updating: iconSet("stale"),
  offline: iconSet("offline"),
  unbound: iconSet("stale"),
};
const STATE = {
  fresh: { badge: "", color: "#3FB950", title: "GitHub → Show — up to date" },
  updating: { badge: "●", color: "#D29922", title: "GitHub → Show — waiting for Chrome to install the update" },
  stale: { badge: "●", color: "#D29922", title: "GitHub → Show — source changed (click for menu)" },
  offline: { badge: "×", color: "#6E7681", title: `GitHub → Show — viewer offline (${VIEWER_URL})` },
  unbound: { badge: "!", color: "#D29922", title: "GitHub → Show — ⌘⇧O isn't bound (click to fix)" },
};

// A key rotation changes the extension id, and Chrome's shortcut registry keys on the OLD id
// without following — the chords then do nothing at all: no SW wake, no badge, no log, so every
// failure surface we built stays silent. getAll() is the only honest read (the on-disk
// Preferences entry can name the live id and still be dead), and only a human re-typing them at
// chrome://extensions/shortcuts can rebind.
const CHORDS = ["open-in-nvim"];   // the name Chrome keyed ⌘⇧O to; renaming it drops the binding

async function chordsUnbound() {
  const cmds = await chrome.commands.getAll();
  return CHORDS.some((name) => !cmds.find((c) => c.name === name)?.shortcut);
}

// Only the forced copy owns the chords; an unpacked copy loaded for hacking never holds them,
// and flagging that would just nag — and mask its stale→reload HMR path.
async function stateWithChords() {
  const state = await computeState();
  if (state !== "fresh" || await developmentInstall) {
    return state;
  }
  return (await chordsUnbound()) ? "unbound" : "fresh";
}

function iconSet(name) {
  return { 16: `icons/${name}-16.png`, 32: `icons/${name}-32.png`, 48: `icons/${name}-48.png`, 128: `icons/${name}-128.png` };
}

let shown = null;   // last-painted state — repaint only on change, so the 2s poll never flickers the icon

async function apply(state) {
  await chrome.storage.session.set({ state });   // the popup reads this
  if (Date.now() < feedbackUntil || state === shown) {
    return;
  }
  shown = state;
  const s = STATE[state];
  await chrome.action.setIcon({ path: ICONS[state] });
  await chrome.action.setBadgeText({ text: s.badge });
  await chrome.action.setBadgeBackgroundColor({ color: s.color });
  let title = s.title;
  if (state === "fresh") {
    const { lastHandoffMs } = await chrome.storage.session.get("lastHandoffMs");
    if (Number.isFinite(lastHandoffMs)) title += ` · Last PR sent to Canopy in ${lastHandoffMs} ms`;
  }
  await chrome.action.setTitle({ title });
}

async function extensionStatus() {
  try {
    const r = await fetch(`${VIEWER_URL}/ext-mtime`);
    if (!r.ok) {
      return null;
    }
    const j = await r.json();
    return typeof j?.mtime === "number" ? j : null;
  } catch {
    return null;
  }
}

// session storage is wiped on a real extension reload but survives SW sleep/wake — so an
// absent baseline means "freshly reloaded, this disk state is current"; a later higher
// mtime means the source moved past what's loaded.
let lastDiskMtime = null;   // what maybeAutoReload watches for quiet

async function computeState() {
  const status = await extensionStatus();
  if (status === null) {
    return "offline";
  }
  if (!(await developmentInstall)) {
    const published = status.published?.[chrome.runtime.id];
    return newerVersion(published, chrome.runtime.getManifest().version) ? "updating" : "fresh";
  }
  const m = status.mtime;
  lastDiskMtime = m;
  const { baseline } = await chrome.storage.session.get("baseline");
  if (baseline === undefined) {
    await chrome.storage.session.set({ baseline: m });
    return "fresh";
  }
  return m > baseline ? "stale" : "fresh";
}

// stale doesn't wait for a human: once the on-disk source stops moving (QUIET_MS with no new
// mtime — mid-edit saves would otherwise reload per keystroke), self-reload. No content script
// anymore, so there's nothing to re-inject into open tabs — a bare reload is the whole story.
// SW sleep resets the quiet timer — worst case the reload waits for the next wake, never loops
// (reload wipes the session baseline, so the new copy reads as fresh).
const QUIET_MS = 1500;   // just enough to let a burst of saves settle — this is HMR latency, spend it carefully
let staleMtime = null;
let staleSince = 0;

const developmentInstall = chrome.management.getSelf().then(self => self.installType === "development", () => false);
chrome.runtime.onUpdateAvailable.addListener(() => chrome.runtime.reload());

function newerVersion(published, installed) {
  if (typeof published !== "string" || !/^\d+(?:\.\d+){0,3}$/.test(published)) return false;
  const next = published.split(".").map(Number);
  const current = installed.split(".").map(Number);
  for (let i = 0; i < 4; i++) {
    const diff = (next[i] || 0) - (current[i] || 0);
    if (diff) return diff > 0;
  }
  return false;
}

let checkingUpdate = false;
async function requestPublishedUpdate() {
  if (checkingUpdate) return;
  checkingUpdate = true;
  try {
    const { retryUpdateAt } = await chrome.storage.session.get("retryUpdateAt");
    if (Date.now() < retryUpdateAt) return;
    const minute = 60_000;
    await chrome.storage.session.set({ retryUpdateAt: Date.now() + 5 * minute });
    const { status } = await chrome.runtime.requestUpdateCheck();
    if (status === "throttled") {
      await chrome.storage.session.set({ retryUpdateAt: Date.now() + 60 * minute });
    }
  } catch {
    // The saved deadline also bounds retries after a runtime error.
  } finally {
    checkingUpdate = false;
  }
}

function maybeAutoReload() {
  if (lastDiskMtime !== staleMtime) {
    staleMtime = lastDiskMtime;
    staleSince = Date.now();
    return;
  }
  if (Date.now() - staleSince < QUIET_MS) {
    return;
  }
  chrome.runtime.reload();
}

async function poll() {
  const state = await stateWithChords();
  await apply(state);
  if (state === "stale") {
    maybeAutoReload();
  } else {
    staleMtime = null;
    if (state === "updating") await requestPublishedUpdate();
  }
}

// The popup asks for a fresh read the moment it opens.
chrome.runtime.onMessage.addListener((msg, _s, respond) => {
  if (msg?.type !== "ext-state") {
    return;
  }
  stateWithChords().then((state) => {
    apply(state);
    respond({ state });
  });
  return true;
});

// The toolbar action only lights up where it can act — github.com. declarativeContent
// keeps the URL-only contract: the matcher runs inside the browser, no tabs/page access.
// Keyboard chords still fire everywhere (openActiveTab already rejects non-GitHub URLs).
chrome.runtime.onInstalled.addListener(() => {
  chrome.action.disable();
  chrome.declarativeContent.onPageChanged.removeRules(undefined, () => {
    chrome.declarativeContent.onPageChanged.addRules([
      {
        conditions: [
          new chrome.declarativeContent.PageStateMatcher({
            pageUrl: { hostEquals: "github.com", schemes: ["https"] },
          }),
        ],
        actions: [new chrome.declarativeContent.ShowAction()],
      },
    ]);
  });
});

poll();
setInterval(poll, 2000);

// setInterval dies with the sleeping service worker; an alarm wakes it so the badge
// stays honest and the force-installed copy pulls new packs without a human poke.
chrome.alarms.create("poll", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "poll") {
    poll();
  }
});
