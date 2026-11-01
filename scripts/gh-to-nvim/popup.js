// VIEWER_URL / VIEWER_PORT come from config.js (loaded first in popup.html).
// The status strip shows only when something needs doing; all's-well says nothing.
const COPY = {
  stale: { label: "Source changed", detail: "reload to apply your edits" },
  offline: { label: "Viewer offline", detail: `nothing on ${VIEWER_URL}` },
  unbound: { label: "Shortcuts unbound", detail: "Chrome dropped them" },
};

const HOST = "com.loops.gh_to_nvim";
const launchBtn = document.getElementById("launch");
const bindBtn = document.getElementById("bind");

function render(state) {
  const c = COPY[state];
  document.getElementById("status").hidden = !c;
  if (c) {
    document.getElementById("dot").className = `dot ${state}`;
    document.getElementById("label").textContent = c.label;
    document.getElementById("detail").textContent = c.detail;
  }
  launchBtn.hidden = state !== "offline";
  bindBtn.hidden = state !== "unbound";
  document.getElementById("reload").hidden = state !== "stale";
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

// The one main action. On a PR it names what canopy will open — the forest, the branch, the line
// selected on GitHub — and the server imports the PR if it isn't local yet. Opening the popup is the
// activeTab gesture, so the tab's URL is readable here with no page access.
const PR = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)/;
const btn = document.getElementById("canopy");
let onPR = false;

function selectedLine(url) {
  const m = url.match(/#diff-[0-9a-f]+([RL])(\d+)/);
  return m ? (m[1] === "R" ? `at line ${m[2]}` : "at the file (an old line)") : "";
}

async function showTarget() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const url = tab?.url || "";
  document.getElementById("helix").hidden = !url.startsWith("https://github.com/");
  const m = url.match(PR);
  if (!m) {
    return;
  }
  onPR = true;
  const what = document.getElementById("canopy-what");
  const detail = document.getElementById("canopy-detail");
  const at = selectedLine(url);
  document.getElementById("canopy-title").textContent = "Open in canopy";
  what.textContent = `#${m[2]}`;
  detail.textContent = at;
  btn.classList.add("pending");
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
  btn.classList.remove("pending");
  if (!info?.ok || !info.branch) {
    detail.textContent = ["imports the PR", at].filter(Boolean).join(" · ");
    return;
  }
  what.textContent = info.project ? `⧉ ${info.project}` : info.branch;
  detail.textContent = [info.project ? info.branch : "", at, info.decision?.toLowerCase().replace(/_/g, " ")]
    .filter(Boolean)
    .join(" · ");
  for (const c of info.children || []) {
    detail.appendChild(document.createElement("br"));
    const kid = document.createElement("span");
    kid.textContent = c.seated ? `└ ${c.branch}` : `└ ${c.branch} (orphaned)`;
    kid.className = c.seated ? "" : "orphan";
    detail.appendChild(kid);
  }
}

showTarget();

btn.addEventListener("click", () => {
  chrome.runtime.sendMessage(onPR ? { type: "open-url", target: "viewer" } : { type: "open-canopy", route: "/v2" });
  window.close();
});

launchBtn.addEventListener("click", () => {
  launchBtn.disabled = true;
  launchBtn.textContent = "Starting…";
  chrome.runtime.sendNativeMessage(HOST, { action: "launch" }, (res) => {
    if (chrome.runtime.lastError || !res?.ok) {
      const why = chrome.runtime.lastError?.message || res?.err || "native host not installed";
      launchBtn.textContent = "Start the viewer";
      launchBtn.disabled = false;
      document.getElementById("detail").textContent = `didn't start — ${why}`;
      return;
    }
    // server is starting; poll the background's reachability check until it's up
    let tries = 0;
    const tick = () => {
      tries += 1;
      chrome.runtime.sendMessage({ type: "ext-state" }, (s) => {
        if (!chrome.runtime.lastError && s?.state && s.state !== "offline") {
          render(s.state);
          launchBtn.textContent = "Start the viewer";
          launchBtn.disabled = false;
        } else if (tries < 20) {
          setTimeout(tick, 500);
        } else {
          launchBtn.textContent = "Start the viewer";
          launchBtn.disabled = false;
          document.getElementById("detail").textContent = "started, but still unreachable";
        }
      });
    };
    setTimeout(tick, 500);
  });
});

document.getElementById("helix").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "open-url", target: "nvim" });
  window.close();   // result lands on the toolbar badge (and a notification on failure)
});

document.getElementById("reload").addEventListener("click", () => {
  chrome.runtime.reload();
  window.close();
});
