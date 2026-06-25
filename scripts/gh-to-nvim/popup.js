const VIEWER = "http://localhost:62497";

const COPY = {
  fresh: { label: "Up to date", detail: "loaded copy matches disk" },
  stale: { label: "Source changed", detail: "reload to apply your edits" },
  offline: { label: "Viewer offline", detail: `unreachable on ${VIEWER}` },
  unknown: { label: "Checking…", detail: "viewer :62497" },
};

function render(state) {
  const c = COPY[state] || COPY.unknown;
  document.getElementById("dot").className = `dot ${state}`;
  document.getElementById("label").textContent = c.label;
  document.getElementById("detail").textContent = c.detail;
}

chrome.runtime.sendMessage({ type: "ext-state" }, (res) => {
  render(chrome.runtime.lastError ? "offline" : res?.state || "unknown");
});

document.getElementById("reload").addEventListener("click", () => {
  chrome.runtime.reload();
  window.close();
});

document.getElementById("viewer").addEventListener("click", () => {
  chrome.tabs.create({ url: VIEWER });
  window.close();
});
