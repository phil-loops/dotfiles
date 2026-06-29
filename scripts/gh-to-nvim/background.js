importScripts("./config.js");   // VIEWER_URL — single source of truth (see config.js)

const HOST = "com.loops.gh_to_nvim";   // native host that launches the viewer (idempotent stack-review-serve)

// Content scripts can't reach the native host — relay a launch request through the SW. The host
// runs stack-review-serve (a no-op if already up), so the o-key recovery path can auto-start a
// dead viewer instead of just reporting "offline".
chrome.runtime.onMessage.addListener((msg, _s, respond) => {
  if (msg?.type !== "launch") {
    return;
  }
  try {
    chrome.runtime.sendNativeMessage(HOST, { action: "launch" }, (res) => {
      respond(chrome.runtime.lastError ? { ok: false, err: chrome.runtime.lastError.message } : (res || { ok: false, err: "no response" }));
    });
  } catch (e) {
    respond({ ok: false, err: String(e) });
  }
  return true;
});

// after a popup "reload extension": the new content script isn't in the tab that was open, and
// reloading the extension can't re-inject it — so the popup flags the active tab here and this
// (freshly-restarted) SW refreshes it once the new code is live.
chrome.storage.local.get("refreshTab").then(({ refreshTab }) => {
  if (refreshTab == null) return;
  chrome.storage.local.remove("refreshTab");
  chrome.tabs.reload(refreshTab).catch(() => {});
});

// The content script runs on https://github.com and can't fetch http://localhost
// (mixed content) — the service worker can, via host_permissions, so relay here.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type !== "from-github") {
    return;
  }
  // default endpoint is the PR opener; a blob open targets /open-blob (same relay past the wall)
  const endpoint = msg.endpoint || "/from-github";
  console.log("[gh-to-nvim] relay →", `${VIEWER_URL}${endpoint}`, msg.payload);
  fetch(`${VIEWER_URL}${endpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(msg.payload),
  })
    .then(async (r) => {
      const body = await r.json().catch(() => null);
      console.log("[gh-to-nvim] relay ←", r.status, body);
      sendResponse({ status: r.status, body });
    })
    .catch((err) => {
      console.error("[gh-to-nvim] relay fetch failed:", String(err));
      sendResponse({ status: 0, error: String(err) });
    });
  return true;
});

const ICONS = {
  fresh: iconSet("fresh"),
  stale: iconSet("stale"),
  offline: iconSet("offline"),
};
const STATE = {
  fresh: { badge: "", color: "#3FB950", title: "GitHub → nvim — up to date" },
  stale: { badge: "●", color: "#D29922", title: "GitHub → nvim — source changed (click for menu)" },
  offline: { badge: "×", color: "#6E7681", title: `GitHub → nvim — viewer offline (${VIEWER_URL})` },
};

function iconSet(name) {
  return { 16: `icons/${name}-16.png`, 32: `icons/${name}-32.png`, 48: `icons/${name}-48.png`, 128: `icons/${name}-128.png` };
}

let shown = null;   // last-painted state — repaint only on change, so the 2s poll never flickers the icon

async function apply(state) {
  await chrome.storage.session.set({ state });   // the popup reads this
  if (state === shown) {
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
async function computeState() {
  const m = await diskMtime();
  if (m === null) {
    return "offline";
  }
  const { baseline } = await chrome.storage.session.get("baseline");
  if (baseline === undefined) {
    await chrome.storage.session.set({ baseline: m });
    return "fresh";
  }
  return m > baseline ? "stale" : "fresh";
}

async function poll() {
  await apply(await computeState());
}

// The popup asks for a fresh read the moment it opens.
chrome.runtime.onMessage.addListener((msg, _s, respond) => {
  if (msg?.type !== "ext-state") {
    return;
  }
  computeState().then((state) => {
    apply(state);
    respond({ state });
  });
  return true;
});

poll();
setInterval(poll, 2000);
