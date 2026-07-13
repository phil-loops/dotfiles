// VIEWER_URL / VIEWER_PORT come from config.js (loaded first in popup.html).
const COPY = {
  fresh: { label: "Up to date", detail: "loaded copy matches disk" },
  stale: { label: "Source changed", detail: "reload to apply your edits" },
  offline: { label: "Viewer offline", detail: `unreachable on ${VIEWER_URL}` },
  unbound: { label: "Shortcuts unbound", detail: "Chrome dropped them — rebind to restore ⌘⇧O" },
  unknown: { label: "Checking…", detail: `viewer :${VIEWER_PORT}` },
};

const HOST = "com.loops.gh_to_nvim";
const launchBtn = document.getElementById("launch");
const bindBtn = document.getElementById("bind");

function render(state) {
  const c = COPY[state] || COPY.unknown;
  document.getElementById("dot").className = `dot ${state}`;
  document.getElementById("label").textContent = c.label;
  document.getElementById("detail").textContent = c.detail;
  launchBtn.hidden = state !== "offline";
  bindBtn.hidden = state !== "unbound";
}

// Chrome won't let anything but a human assign a shortcut — not the extension, not an edit to the
// Preferences file (it persists and is ignored). So the most we can do is drive them to the page.
bindBtn.addEventListener("click", () => {
  chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
  window.close();
});

function refresh() {
  chrome.runtime.sendMessage({ type: "ext-state" }, (res) => {
    render(chrome.runtime.lastError ? "offline" : res?.state || "unknown");
  });
}

refresh();

// The failure surface: background's fail() opens this popup after storing the error (macOS may
// have swallowed the notification), so a recent lastError renders as a red strip up top.
chrome.storage.session.get("lastError").then(({ lastError }) => {
  if (!lastError || Date.now() - lastError.at > 5 * 60 * 1000) {
    return;
  }
  const el = document.getElementById("last-error");
  el.classList.toggle("warn", !!lastError.warn);
  el.textContent = `${lastError.warn ? "⚠" : "✗"} ${lastError.text}`;
  const when = document.createElement("span");
  when.className = "when";
  const secs = Math.round((Date.now() - lastError.at) / 1000);
  when.textContent = secs < 5 ? "just now" : secs < 120 ? `${secs}s ago` : `${Math.round(secs / 60)}m ago`;
  el.appendChild(when);
  el.hidden = false;
});

// The old in-page forest chip, relocated: opening the popup is the activeTab gesture, so the
// tab URL is readable here — no page access needed. Shows which forest this PR's branch belongs
// to (+ orphaned children), links to the viewer node. Quietly absent off PRs or when offline.
async function showForest() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const m = (tab?.url || "").match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)/);
  if (!m) {
    return;
  }
  const box = document.getElementById("forest");
  document.getElementById("forest-name").textContent = "⧉ finding forest…";
  box.classList.add("pending");
  box.hidden = false;
  let info = null;
  try {
    const r = await fetch(`${VIEWER_URL}/pr-forest`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ repo: m[1], number: m[2] }),
    });
    info = r.ok ? await r.json() : null;
  } catch {
    info = null;
  }
  if (!info?.ok || !info.branch) {
    box.classList.add("gone");
    setTimeout(() => {
      box.hidden = true;
      box.classList.remove("gone", "pending");
    }, 260);
    return;
  }
  box.classList.remove("pending");
  document.getElementById("forest-name").textContent = `⧉ ${info.project || info.branch}`;
  const detail = document.getElementById("forest-detail");
  detail.textContent = info.branch + (info.decision ? ` · ${info.decision.toLowerCase().replace(/_/g, " ")}` : "");
  for (const c of info.children || []) {
    detail.appendChild(document.createElement("br"));
    const kid = document.createElement("span");
    kid.textContent = c.seated ? `└ ${c.branch}` : `└ ${c.branch} (orphaned)`;
    kid.className = c.seated ? "" : "orphan";
    detail.appendChild(kid);
  }
  box.href = `${VIEWER_URL}${info.route}`;
}

showForest();

launchBtn.addEventListener("click", () => {
  launchBtn.disabled = true;
  launchBtn.textContent = "Launching…";
  chrome.runtime.sendNativeMessage(HOST, { action: "launch" }, (res) => {
    if (chrome.runtime.lastError || !res?.ok) {
      const why = chrome.runtime.lastError?.message || res?.err || "native host not installed";
      launchBtn.textContent = "▶  Launch viewer";
      launchBtn.disabled = false;
      document.getElementById("detail").textContent = `launch failed — ${why}`;
      return;
    }
    // server is starting; poll the background's reachability check until it's up
    let tries = 0;
    const tick = () => {
      tries += 1;
      chrome.runtime.sendMessage({ type: "ext-state" }, (s) => {
        if (!chrome.runtime.lastError && s?.state && s.state !== "offline") {
          render(s.state);
          launchBtn.textContent = "▶  Launch viewer";
          launchBtn.disabled = false;
        } else if (tries < 20) {
          setTimeout(tick, 500);
        } else {
          launchBtn.textContent = "▶  Launch viewer";
          launchBtn.disabled = false;
          document.getElementById("detail").textContent = "started, but still unreachable";
        }
      });
    };
    setTimeout(tick, 500);
  });
});

document.getElementById("open-nvim").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "open-url", target: "nvim" });
  window.close();   // result lands on the toolbar badge (and a notification on failure)
});

document.getElementById("reload").addEventListener("click", () => {
  chrome.runtime.reload();
  window.close();
});

// Same route as ⌘⇧U on a PR: the server resolves the branch's forest node (importing the PR if
// it isn't local yet) and the SW opens it. Off a PR there's no node to aim at, so: viewer home.
document.getElementById("viewer").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+/.test(tab?.url || "")) {
    chrome.runtime.sendMessage({ type: "open-url", target: "viewer" });
  } else {
    chrome.tabs.create({ url: VIEWER_URL });
  }
  window.close();
});
