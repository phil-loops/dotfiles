const FILE_BTN = "gh-nvim-file-btn";
const VIEWER_URL = "http://localhost:62497";

console.log("[gh-to-nvim] content script loaded:", location.pathname);

function parsePr() {
  const m = location.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
  if (!m) {
    return null;
  }
  return { repo: `${m[1]}/${m[2]}`, number: Number(m[3]) };
}

function send(payload) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage({ type: "from-github", payload }, (res) => {
        const err = chrome.runtime.lastError;
        if (err) {
          console.warn("[gh-to-nvim] sendMessage failed:", err.message);
          resolve({ status: 0, error: err.message });
        } else {
          resolve(res);
        }
      });
    } catch (e) {
      // Thrown when the content script is orphaned (extension reloaded under an
      // open tab) — hard-reload the tab. Surface it instead of hanging on "…".
      console.warn("[gh-to-nvim] context invalidated — hard-reload the tab:", String(e));
      resolve({ status: 0, error: "extension reloaded — refresh this tab" });
    }
  });
}

function reset(btn, label) {
  btn.textContent = label;
  btn.disabled = false;
  btn.classList.remove("gh-nvim-ok", "gh-nvim-err");
}

async function fire(btn, payload, label, okText) {
  btn.disabled = true;
  btn.textContent = "…";
  const res = await send(payload);
  const ok = res?.status === 200 && res.body?.ok;
  btn.classList.add(ok ? "gh-nvim-ok" : "gh-nvim-err");
  btn.textContent = ok ? okText(res.body) : "✗";
  btn.title = ok
    ? `opened ${res.body.branch}`
    : `failed: ${res?.body?.err || res?.error || res?.status || "error"}`;
  setTimeout(() => reset(btn, label), 4000);
}

function makeFab(pr) {
  const box = document.createElement("div");
  box.id = "gh-nvim-fab";

  const nvim = document.createElement("button");
  nvim.className = "gh-nvim-fab-btn";
  nvim.textContent = "→ nvim";
  nvim.title = `Import PR #${pr.number} into the forest viewer`;
  nvim.addEventListener("click", () =>
    fire(nvim, { number: pr.number, repo: pr.repo }, "→ nvim", (b) => `✓ ${b.branch}`),
  );

  const viewer = document.createElement("button");
  viewer.className = "gh-nvim-fab-btn";
  viewer.textContent = "→ viewer";
  viewer.title = "Import + open this PR in the forest viewer";
  viewer.addEventListener("click", async () => {
    viewer.disabled = true;
    viewer.textContent = "…";
    const res = await send({ number: pr.number, repo: pr.repo });
    const ok = res?.status === 200 && res.body?.ok;
    if (ok) {
      window.open(`${VIEWER_URL}/${res.body.branch}`, "_blank");
    }
    viewer.classList.add(ok ? "gh-nvim-ok" : "gh-nvim-err");
    viewer.textContent = ok ? "✓" : "✗";
    viewer.title = ok ? `opened ${res.body.branch}` : `failed: ${res?.body?.err || res?.error || res?.status || "error"}`;
    setTimeout(() => reset(viewer, "→ viewer"), 4000);
  });

  box.append(nvim, viewer);
  return box;
}

function toast(text, ok) {
  let el = document.getElementById("gh-nvim-toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "gh-nvim-toast";
    document.body.appendChild(el);
  }
  el.textContent = text;
  el.classList.toggle("gh-nvim-err", !ok);
  el.classList.add("gh-nvim-show");
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.classList.remove("gh-nvim-show"), 3000);
}

// ⌥-click a right-side (new-file) line number → open that exact file+line in nvim.
// Capture phase + preventDefault so we beat GitHub's own select-this-line handler.
async function onLineClick(e) {
  if (!e.altKey) {
    return;
  }
  const cell = e.target.closest('td.new-diff-line-number[data-diff-side="right"][data-line-number]');
  if (!cell) {
    return;
  }
  const table = cell.closest('table[aria-label^="Diff for: "]');
  const pr = parsePr();
  if (!table || !pr) {
    return;
  }
  e.preventDefault();
  e.stopPropagation();
  const path = table.getAttribute("aria-label").replace(/^Diff for: /, "");
  const line = cell.getAttribute("data-line-number");
  toast(`→ ${path}:${line} …`, true);
  const res = await send({ number: pr.number, repo: pr.repo, path, line });
  const ok = res?.status === 200 && res.body?.ok;
  toast(ok ? `✓ ${path}:${line}` : `✗ ${res?.body?.err || res?.error || res?.status || "failed"}`, ok);
}

function altToggle(e) {
  document.body.classList.toggle("gh-nvim-alt", e.altKey);
}

function makeFileButton(pr, path) {
  const btn = document.createElement("button");
  btn.className = FILE_BTN;
  btn.type = "button";
  btn.textContent = "nvim";
  btn.title = `Open ${path} in nvim`;
  btn.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    fire(btn, { number: pr.number, repo: pr.repo, path, line: 1 }, "nvim", () => "✓");
  });
  return btn;
}

function injectFileButtons(pr) {
  for (const wrap of document.querySelectorAll('div[data-diff-header-wrapper="true"]')) {
    if (wrap.querySelector(`.${FILE_BTN}`)) {
      continue;
    }
    const path = wrap.querySelector("button[data-file-path]")?.getAttribute("data-file-path");
    if (!path) {
      continue;
    }
    const viewed = wrap.querySelector('button[aria-label$="Viewed"]');
    const btn = makeFileButton(pr, path);
    if (viewed) {
      viewed.before(btn);
    } else {
      wrap.appendChild(btn);
    }
  }
}

function tick() {
  const pr = parsePr();
  const fab = document.getElementById("gh-nvim-fab");
  if (!pr) {
    if (fab) {
      fab.remove();
    }
    return;
  }
  if (!fab) {
    document.body.appendChild(makeFab(pr));
  }
  injectFileButtons(pr);
}

let scheduled = false;
function schedule() {
  if (scheduled) {
    return;
  }
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    tick();
  });
}

tick();
new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
setInterval(tick, 3000);
document.addEventListener("click", onLineClick, true);
document.addEventListener("keydown", altToggle, true);
document.addEventListener("keyup", altToggle, true);
window.addEventListener("blur", () => document.body.classList.remove("gh-nvim-alt"));
