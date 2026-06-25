const VIEWER = "http://localhost:62497";

// The content script runs on https://github.com and can't fetch http://localhost
// (mixed content) — the service worker can, via host_permissions, so relay here.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type !== "from-github") {
    return;
  }
  console.log("[gh-to-nvim] relay →", `${VIEWER}/from-github`, msg.payload);
  fetch(`${VIEWER}/from-github`, {
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
  offline: { badge: "×", color: "#6E7681", title: `GitHub → nvim — viewer offline (${VIEWER})` },
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
    const r = await fetch(`${VIEWER}/ext-mtime`);
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
