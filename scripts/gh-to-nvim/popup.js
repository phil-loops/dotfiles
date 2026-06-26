const VIEWER = "http://localhost:62497";

const COPY = {
  fresh: { label: "Up to date", detail: "loaded copy matches disk" },
  stale: { label: "Source changed", detail: "reload to apply your edits" },
  offline: { label: "Viewer offline", detail: `unreachable on ${VIEWER}` },
  unknown: { label: "Checking…", detail: "viewer :62497" },
};

const HOST = "com.loops.gh_to_nvim";
const launchBtn = document.getElementById("launch");

function render(state) {
  const c = COPY[state] || COPY.unknown;
  document.getElementById("dot").className = `dot ${state}`;
  document.getElementById("label").textContent = c.label;
  document.getElementById("detail").textContent = c.detail;
  launchBtn.hidden = state !== "offline";
}

function refresh() {
  chrome.runtime.sendMessage({ type: "ext-state" }, (res) => {
    render(chrome.runtime.lastError ? "offline" : res?.state || "unknown");
  });
}

refresh();

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

document.getElementById("reload").addEventListener("click", () => {
  chrome.runtime.reload();
  window.close();
});

document.getElementById("viewer").addEventListener("click", () => {
  chrome.tabs.create({ url: VIEWER });
  window.close();
});
