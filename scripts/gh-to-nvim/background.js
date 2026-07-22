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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForViewer(timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if ((await diskMtime()) !== null) {
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
    title: "GitHub → nvim",
    message: text,
  });
}

// macOS can deny Chrome's alert helper its notification permission (it's a separate entry in
// System Settings), silently dropping every notify() — so a failure also opens the popup, the
// one surface the OS can't suppress. The popup renders lastError from session storage.
async function fail(text) {
  await chrome.storage.session.set({ lastError: { text, at: Date.now() } });
  await badge("✗", "#F85149", 10000);
  await chrome.action.setTitle({ title: `GitHub → nvim — failed: ${text}` });
  notify(text.slice(0, 200));
  try {
    await chrome.action.openPopup();
  } catch {
    // no focused window / popup already open — badge + title still carry the error
  }
}

const reason = (res) => res?.body?.err || res?.error || `status ${res?.status}`;

// Self-healing open: dead viewer → native-host launch + wait + one retry; cold first open
// (504 — the worktree/nvim still warming) → brief wait + retry.
async function openWithRecovery(payload) {
  await badge("…", "#58A6FF", 30000);
  let res = await post(payload);
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

async function openActiveTab(target) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const url = tab?.url || "";   // readable only because the gesture granted activeTab
  if (!url.startsWith("https://github.com/")) {
    await fail("not a GitHub page");
    return;
  }
  const res = await openWithRecovery({ url, open: target });
  const ok = res.status === 200 && res.body?.ok;
  if (!ok) {
    await fail(String(reason(res)));
    return;
  }
  if (target === "viewer" && res.body.path) {
    chrome.tabs.create({ url: `${VIEWER_URL}${res.body.path}` });
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

chrome.commands.onCommand.addListener((cmd) => {
  if (cmd === "open-in-nvim") {
    openActiveTab("nvim");
  } else if (cmd === "open-in-viewer") {
    openActiveTab("viewer");
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
let lastPrewarmed = "";

function prewarm(url) {
  const m = (url || "").match(PR_RE);
  if (!m || m[0] === lastPrewarmed) {
    return;   // not a PR, or the same one — clicking a line rewrites the hash, not the PR
  }
  lastPrewarmed = m[0];
  fetch(`${VIEWER_URL}/open-url`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url: m[0], open: "prewarm" }),
    signal: AbortSignal.timeout(POST_TIMEOUT_MS),
  }).catch(() => {});   // viewer down → the chord's recovery ladder still handles it
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

// The popup's "→ nvim this page" button routes here — opening the popup is itself the
// activeTab gesture, so the tab URL is readable for the click that follows.
chrome.runtime.onMessage.addListener((msg, _s, respond) => {
  if (msg?.type !== "open-url") {
    return;
  }
  openActiveTab(msg.target || "nvim").then(() => respond({ ok: true }));
  return true;
});

const ICONS = {
  fresh: iconSet("fresh"),
  stale: iconSet("stale"),
  offline: iconSet("offline"),
  unbound: iconSet("stale"),
};
const STATE = {
  fresh: { badge: "", color: "#3FB950", title: "GitHub → nvim — up to date" },
  stale: { badge: "●", color: "#D29922", title: "GitHub → nvim — source changed (click for menu)" },
  offline: { badge: "×", color: "#6E7681", title: `GitHub → nvim — viewer offline (${VIEWER_URL})` },
  unbound: { badge: "!", color: "#D29922", title: "GitHub → nvim — ⌘⇧O isn't bound (click to fix)" },
};

// A key rotation changes the extension id, and Chrome's shortcut registry keys on the OLD id
// without following — the chords then do nothing at all: no SW wake, no badge, no log, so every
// failure surface we built stays silent. getAll() is the only honest read (the on-disk
// Preferences entry can name the live id and still be dead), and only a human re-typing them at
// chrome://extensions/shortcuts can rebind.
const CHORDS = ["open-in-nvim", "open-in-viewer"];

async function chordsUnbound() {
  const cmds = await chrome.commands.getAll();
  return CHORDS.some((name) => !cmds.find((c) => c.name === name)?.shortcut);
}

// Only the forced copy owns the chords; an unpacked copy loaded for hacking never holds them,
// and flagging that would just nag — and mask its stale→reload HMR path.
async function stateWithChords() {
  const state = await computeState();
  if (state !== "fresh" || installType === "development") {
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
  await chrome.action.setTitle({ title: s.title });
}

async function diskMtime() {
  try {
    const r = await fetch(`${VIEWER_URL}/ext-mtime`);
    if (!r.ok) {
      return null;
    }
    const j = await r.json();
    return typeof j?.mtime === "number" ? j.mtime : null;
  } catch {
    return null;
  }
}

// session storage is wiped on a real extension reload but survives SW sleep/wake — so an
// absent baseline means "freshly reloaded, this disk state is current"; a later higher
// mtime means the source moved past what's loaded.
let lastDiskMtime = null;   // what maybeAutoReload watches for quiet

async function computeState() {
  const m = await diskMtime();
  if (m === null) {
    return "offline";
  }
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

// "development" = unpacked (runtime.reload re-reads source from disk = real HMR).
// Anything else = the force-installed CRX, where runtime.reload would rerun the SAME
// installed bytes and then read as fresh — a silent lie. That copy asks the updater
// instead, which pulls whatever gh-to-nvim-pack last published to the local server.
//
// Default to NOT development: defaulting the other way is what wedged the forced copy — if
// getSelf never lands, every stale tick called runtime.reload(), which re-ran the same bytes and
// reseeded the baseline to "fresh", so requestUpdateCheck was never reached and the installed copy
// could not update itself at all (0.3.9 took ~2h to land, via Chrome's own slow cycle). Guessing
// "packed" costs a dev copy one wasted update check; guessing "dev" costs the real copy every update.
let installType = "admin";
chrome.management.getSelf((info) => {
  if (info?.installType) {
    installType = info.installType;
  }
});
chrome.runtime.onUpdateAvailable.addListener(() => chrome.runtime.reload());

const UPDATE_ASK_MS = 5000;   // requestUpdateCheck throttles hard callers — pace it, but 60s WAS the HMR floor
let lastUpdateAsk = 0;

function maybeAutoReload() {
  if (lastDiskMtime !== staleMtime) {
    staleMtime = lastDiskMtime;
    staleSince = Date.now();
    return;
  }
  if (Date.now() - staleSince < QUIET_MS) {
    return;
  }
  if (installType === "development") {
    chrome.runtime.reload();
    return;
  }
  if (Date.now() - lastUpdateAsk < UPDATE_ASK_MS) {
    return;
  }
  lastUpdateAsk = Date.now();
  chrome.runtime.requestUpdateCheck(() => {});
}

async function poll() {
  const state = await stateWithChords();
  await apply(state);
  if (state === "stale") {
    maybeAutoReload();
  } else {
    staleMtime = null;
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
