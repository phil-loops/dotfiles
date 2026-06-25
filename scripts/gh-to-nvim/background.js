const VIEWER = "http://localhost:62333";

// The content script runs on https://github.com and can't fetch http://localhost
// (mixed content) — the service worker can, via host_permissions, so relay here.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type !== "from-github") {
    return;
  }
  fetch(`${VIEWER}/from-github`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(msg.payload),
  })
    .then(async (r) => sendResponse({ status: r.status, body: await r.json().catch(() => null) }))
    .catch((err) => sendResponse({ status: 0, error: String(err) }));
  return true;
});
