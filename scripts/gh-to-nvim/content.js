const FILE_BTN = "gh-nvim-file-btn";   // VIEWER_URL comes from config.js (loaded first)

console.log("[gh-to-nvim] content script loaded:", location.pathname);

function parsePr() {
  const m = location.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
  if (!m) {
    return null;
  }
  return { repo: `${m[1]}/${m[2]}`, number: Number(m[3]) };
}

async function sha256hex(s) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// the line GitHub has selected (you clicked a line number): the URL hash is
// #diff-<sha256(path)>R<line> (R = the new-file side). GitHub's diff is virtualized so the
// anchor element often isn't in the DOM — resolve the path by hashing each RENDERED diff
// table's path and matching the hash. null → caller falls back to the gm Diffview.
async function selectedLine() {
  const m = location.hash.match(/^#diff-([0-9a-f]+)R(\d+)/);
  if (!m) {
    return null;
  }
  const wantHash = m[1];
  const line = Number(m[2]);
  for (const table of document.querySelectorAll('table[aria-label^="Diff for: "]')) {
    const path = table.getAttribute("aria-label").replace(/^Diff for: /, "");
    if ((await sha256hex(path)) === wantHash) {
      return { path, line };
    }
  }
  console.warn(`[gh-to-nvim] line ${line} selected but its file isn't rendered — falling back to gm`);
  return null;
}

// what an "open in nvim" gesture sends: the selected file+line, else the whole-PR gm Diffview.
async function nvimRequest(pr) {
  const sel = await selectedLine();
  if (sel) {
    return { payload: { number: pr.number, repo: pr.repo, path: sel.path, line: sel.line },
             short: `:${sel.line}`, full: `${sel.path}:${sel.line}` };
  }
  return { payload: { number: pr.number, repo: pr.repo, view: "gm" }, short: "gm", full: "gm Diffview" };
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
  toast("opening in nvim…", true, true);
  const res = await send(payload);
  const ok = res?.status === 200 && res.body?.ok;
  btn.classList.add(ok ? "gh-nvim-ok" : "gh-nvim-err");
  btn.textContent = ok ? okText(res.body) : "✗";
  btn.title = ok
    ? `opened ${res.body.branch}`
    : `failed: ${res?.body?.err || res?.error || res?.status || "error"}`;
  toast(ok ? `✓ opened ${res.body?.branch || ""}` : `✗ ${res?.body?.err || res?.error || res?.status || "failed"}`, ok);
  setTimeout(() => reset(btn, label), 4000);
}

function makeFab(pr) {
  const box = document.createElement("div");
  box.id = "gh-nvim-fab";

  const nvimBtn = document.createElement("button");
  nvimBtn.className = "gh-nvim-fab-btn";
  nvimBtn.textContent = "→ nvim";
  nvimBtn.title = `Open PR #${pr.number} in nvim — the file+line if one is selected, else the whole-PR Diffview (⌥-click any line works too)`;
  nvimBtn.addEventListener("click", async () => {
    const { payload, short } = await nvimRequest(pr);
    fire(nvimBtn, payload, "→ nvim", () => `✓ ${short}`);
  });

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
      // backend owns the route; fall back to the standalone shape if it predates `path`
      const route = res.body.path || `/branch/${res.body.branch}`;
      window.open(`${VIEWER_URL}${route}`, "_blank");
    }
    viewer.classList.add(ok ? "gh-nvim-ok" : "gh-nvim-err");
    viewer.textContent = ok ? "✓" : "✗";
    viewer.title = ok ? `opened ${res.body.branch}` : `failed: ${res?.body?.err || res?.error || res?.status || "error"}`;
    setTimeout(() => reset(viewer, "→ viewer"), 4000);
  });

  box.append(nvimBtn, viewer);
  return box;
}

function toast(text, ok, sticky) {
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
  // sticky = stay up until the result replaces it (a cold open can take several seconds —
  // without this the "opening…" toast vanishes mid-wait and it looks like nothing's happening).
  if (!sticky) {
    el._timer = setTimeout(() => el.classList.remove("gh-nvim-show"), 3000);
  }
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
  toast(`→ ${path}:${line} — opening…`, true, true);
  const res = await send({ number: pr.number, repo: pr.repo, path, line });
  const ok = res?.status === 200 && res.body?.ok;
  toast(ok ? `✓ ${path}:${line}` : `✗ ${res?.body?.err || res?.error || res?.status || "failed"}`, ok);
}

let prewarmedPr = null;
function prewarm(pr) {
  // import the PR's branch (+ materialize its worktree, server-side) in the background, once,
  // so the first real open skips the slow git fetch + worktree build. Path-less = no nvim open.
  if (pr && prewarmedPr !== pr.number) {
    prewarmedPr = pr.number;
    send({ number: pr.number, repo: pr.repo });
  }
}
function altToggle(e) {
  document.body.classList.toggle("gh-nvim-alt", e.altKey);
  if (e.altKey) {
    prewarm(parsePr());
  }
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
    prewarm(pr);   // warm the import + worktree on page load so the first open is fast
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
// "o" (no modifiers, not while typing) → open the selected file+line, else the gm Diffview.
async function onOpenKey(e) {
  if (e.key !== "o" || e.altKey || e.metaKey || e.ctrlKey) {
    return;
  }
  const t = e.target;
  if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)) {
    return;
  }
  const pr = parsePr();
  if (!pr) {
    return;
  }
  e.preventDefault();
  e.stopPropagation();
  const { payload, full } = await nvimRequest(pr);
  toast(`→ ${full} — opening…`, true, true);
  const res = await send(payload);
  const ok = res?.status === 200 && res.body?.ok;
  toast(ok ? `✓ ${full}` : `✗ ${res?.body?.err || res?.error || res?.status || "failed"}`, ok);
}

document.addEventListener("click", onLineClick, true);
document.addEventListener("keydown", altToggle, true);
document.addEventListener("keyup", altToggle, true);
document.addEventListener("keydown", onOpenKey, true);
window.addEventListener("blur", () => document.body.classList.remove("gh-nvim-alt"));
