// VIEWER_URL comes from config.js (loaded first in popup.html).
const HOST = "com.loops.gh_to_nvim";

// Nothing shows when all's well; otherwise one row names the problem and its click is the fix.
const FIX = {
  offline: { label: "Viewer offline", act: "Start", run: startViewer },
  unbound: { label: "Shortcut unbound", act: "Bind ⌘⇧O", run: bindShortcut },
  stale: { label: "Source changed", act: "Reload", run: () => chrome.runtime.reload() },
};

const $ = (id) => document.getElementById(id);
const fixBtn = $("fix");
let fixState = null;

function render(state) {
  const f = FIX[state];
  fixState = f ? state : null;
  fixBtn.hidden = !f;
  if (f) {
    $("dot").className = `dot ${state}`;
    $("fix-label").textContent = f.label;
    $("fix-act").textContent = f.act;
  }
}

fixBtn.addEventListener("click", () => FIX[fixState]?.run());

function refresh() {
  chrome.runtime.sendMessage({ type: "ext-state" }, (res) => {
    render(chrome.runtime.lastError ? "offline" : res?.state || "unknown");
  });
}

// Chrome lets only a human assign a shortcut, so the most we can do is open the page.
function bindShortcut() {
  chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
  window.close();
}

function startViewer() {
  fixBtn.disabled = true;
  $("fix-act").textContent = "Starting…";
  chrome.runtime.sendNativeMessage(HOST, { action: "launch" }, (res) => {
    if (chrome.runtime.lastError || !res?.ok) {
      fixBtn.disabled = false;
      $("fix-label").textContent = `Didn't start — ${chrome.runtime.lastError?.message || res?.err || "native host not installed"}`;
      $("fix-act").textContent = "Retry";
      return;
    }
    let tries = 0;
    const tick = () => {
      tries += 1;
      chrome.runtime.sendMessage({ type: "ext-state" }, (s) => {
        if (!chrome.runtime.lastError && s?.state && s.state !== "offline") {
          fixBtn.disabled = false;
          render(s.state);
          showTarget();
        } else if (tries < 20) {
          setTimeout(tick, 500);
        } else {
          fixBtn.disabled = false;
          $("fix-label").textContent = "Started, but still unreachable";
          $("fix-act").textContent = "Retry";
        }
      });
    };
    setTimeout(tick, 500);
  });
}

refresh();

// background's fail() opens this popup after storing the error (macOS may have swallowed the
// notification), so a recent lastError renders under the card.
chrome.storage.session.get("lastError").then(({ lastError }) => {
  if (!lastError || Date.now() - lastError.at > 5 * 60 * 1000) {
    return;
  }
  const el = $("last-error");
  el.classList.toggle("warn", !!lastError.warn);
  el.textContent = `${lastError.warn ? "⚠" : "✗"} ${lastError.text}`;
  const when = document.createElement("span");
  when.className = "when";
  const secs = Math.round((Date.now() - lastError.at) / 1000);
  when.textContent = secs < 5 ? "just now" : secs < 120 ? `${secs}s ago` : `${Math.round(secs / 60)}m ago`;
  el.appendChild(when);
  el.hidden = false;
});

// On a PR the card names what Show will open — the forest, the branch, the line selected on
// GitHub — and the server imports the PR if it isn't local yet. Opening the popup is the
// activeTab gesture, so the tab's URL is readable here with no page access.
const PR = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/(\d+)/;
const openBtn = $("open");
let onPR = false;

function selectedLine(url) {
  const m = url.match(/#diff-[0-9a-f]+([RL])(\d+)/);
  return m ? (m[1] === "R" ? `line ${m[2]}` : "the file (an old line)") : "";
}

async function showTarget() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const url = tab?.url || "";
  const m = url.match(PR);
  if (!m) {
    return;
  }
  onPR = true;
  const what = $("open-what");
  const detail = $("open-detail");
  const at = selectedLine(url);
  $("open-title").textContent = "Open in Show";
  what.textContent = `#${m[2]}`;
  detail.textContent = at;
  openBtn.classList.add("pending");
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
  openBtn.classList.remove("pending");
  if (!info?.ok || !info.branch) {
    what.textContent = `#${m[2]} · new`;
    detail.textContent = ["imports the PR", at].filter(Boolean).join(" · ");
    return;
  }
  what.textContent = info.project ? `⧉ ${info.project}` : info.branch;
  detail.textContent = [`#${m[2]}`, info.project ? info.branch : "", at, info.decision?.toLowerCase().replace(/_/g, " ")]
    .filter(Boolean)
    .join(" · ");
  for (const c of info.children || []) {
    const kid = document.createElement("span");
    kid.textContent = c.seated ? `└ ${c.branch}` : `└ ${c.branch} (orphaned)`;
    kid.className = c.seated ? "kid" : "kid orphan";
    detail.appendChild(kid);
  }
}

showTarget();

openBtn.addEventListener("click", () => {
  chrome.runtime.sendMessage(onPR ? { type: "open-url", target: "viewer" } : { type: "open-canopy", route: "/v2" });
  window.close();
});
