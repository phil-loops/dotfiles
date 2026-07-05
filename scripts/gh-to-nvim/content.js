const FILE_BTN = "gh-nvim-file-btn";   // VIEWER_URL comes from config.js (loaded first)

console.log("[gh-to-nvim] content script loaded:", location.pathname);

function parsePr() {
  const m = location.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
  if (!m) {
    return null;
  }
  return { repo: `${m[1]}/${m[2]}`, number: Number(m[3]) };
}

// a GitHub file blob view: /<owner>/<repo>/blob/<ref>/<path> with the line in #L<n>.
// ref is informational (we open in the working checkout); path is the repo-relative path.
// NB: a ref containing slashes (feature/x) over-claims path segments — fine for the common
// main/single-segment-ref case, which is what blob "open in nvim" is for.
function parseBlob() {
  const m = location.pathname.match(/^\/([^/]+)\/([^/]+)\/blob\/([^/]+)\/(.+)$/);
  if (!m) {
    return null;
  }
  const lm = location.hash.match(/^#L(\d+)/);
  return {
    repo: `${m[1]}/${m[2]}`,
    ref: decodeURIComponent(m[3]),
    path: decodeURIComponent(m[4]),
    line: lm ? Number(lm[1]) : 1,
  };
}

// a commit or compare page: /<owner>/<repo>/commit/<sha> or /compare/<range>. There's no PR, so a
// selected diff line opens straight into the working checkout via /open-blob (like a blob view).
function parseCommit() {
  const m = location.pathname.match(/^\/([^/]+)\/([^/]+)\/(?:commit|compare)\//);
  return m ? { repo: `${m[1]}/${m[2]}` } : null;
}

async function sha256hex(s) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// the line GitHub has selected (you clicked a line number): the URL hash is
// #diff-<sha256(path)>R<line> (R = the new-file side). GitHub's diff is virtualized so the
// anchor element often isn't in the DOM — resolve the path via the hash→path cache, which
// is warmed from every table that RENDERS (see warmDiffHashCache). null → gm Diffview.
const diffHashCache = new Map();   // sha256(path) → path
const hashedDiffPaths = new Set();
// You can only select a line while its table is rendered, but the table may be virtualized
// OUT again before the open gesture — warming on every tick guarantees the later lookup.
async function warmDiffHashCache() {
  for (const table of document.querySelectorAll('table[aria-label^="Diff for: "]')) {
    const path = table.getAttribute("aria-label").replace(/^Diff for: /, "");
    if (hashedDiffPaths.has(path)) {
      continue;
    }
    hashedDiffPaths.add(path);
    diffHashCache.set(await sha256hex(path), path);
  }
}

let lastSelectionMiss = null;   // {line} when a hash was present but its file couldn't be resolved
async function selectedLine() {
  lastSelectionMiss = null;
  const m = location.hash.match(/^#diff-([0-9a-f]+)R(\d+)/);
  if (!m) {
    return null;
  }
  const wantHash = m[1];
  const line = Number(m[2]);
  await warmDiffHashCache();
  const path = diffHashCache.get(wantHash);
  if (path) {
    return { path, line };
  }
  lastSelectionMiss = { line };
  console.warn(`[gh-to-nvim] line ${line} selected but its file was never seen rendered — falling back to gm`);
  return null;
}

// what an "open in nvim" gesture sends: the selected file+line, else the whole-PR gm Diffview.
async function nvimRequest(pr) {
  const sel = await selectedLine();
  if (sel) {
    return { payload: { number: pr.number, repo: pr.repo, path: sel.path, line: sel.line },
             short: `:${sel.line}`, full: `${sel.path}:${sel.line}` };
  }
  const why = lastSelectionMiss
    ? ` (line ${lastSelectionMiss.line} selected, but its file couldn't be resolved — jump lost)`
    : "";
  return { payload: { number: pr.number, repo: pr.repo, view: "gm" }, short: "gm", full: `gm Diffview${why}` };
}

function send(payload, endpoint) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage({ type: "from-github", payload, endpoint }, (res) => {
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

const reason = (res) => res?.body?.err || res?.error || res?.status || "failed";

// One toast for an open's outcome. A success can still carry a warning (res.body.err on ok) —
// the stack-open stale/force-push backstop landed the cursor at EOF because this checkout differs
// from GitHub. Show that as a sticky warning instead of a bare ✓, so it's never a silent wrong jump.
function resultToast(res, label) {
  const ok = res?.status === 200 && res.body?.ok;
  if (!ok) {
    toast(`✗ ${reason(res)}`, false);
    return false;
  }
  const warn = res.body?.err && String(res.body.err).trim().replace(/^stack-open:\s*/, "");
  if (warn) {
    toast(`⚠ ${label} · ${warn}`, false, true);
  } else {
    toast(`✓ ${label}`, true);
  }
  return true;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ask the SW to start the viewer via the native host (idempotent). resolves {ok, err}.
function launchViewer() {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage({ type: "launch" }, (res) => {
        resolve(chrome.runtime.lastError ? { ok: false, err: chrome.runtime.lastError.message } : (res || { ok: false, err: "no response" }));
      });
    } catch (e) {
      resolve({ ok: false, err: String(e) });
    }
  });
}

// poll the SW's reachability heartbeat (ext-state) until the viewer answers or we give up.
function waitForViewer(timeoutMs) {
  const start = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      chrome.runtime.sendMessage({ type: "ext-state" }, (s) => {
        if (!chrome.runtime.lastError && s?.state && s.state !== "offline") {
          resolve(true);
        } else if (Date.now() - start > timeoutMs) {
          resolve(false);
        } else {
          setTimeout(tick, 500);
        }
      });
    };
    tick();
  });
}

const STAGE = {
  launching: "⏻ viewer offline — launching…",
  waiting: "◷ waiting for viewer…",
  warming: "↻ warming — retrying…",
};

// send(), but self-healing: a dead viewer (status 0) is auto-launched and waited-on before one
// retry; a cold first open (504 — the worktree/nvim still warming) gets a brief wait + retry, so
// the user no longer has to press "o" twice. Narrates each stage in the toast. Returns the final res.
async function openWithRecovery(payload, endpoint, label) {
  toast(`→ ${label} — opening…`, true, true, true);
  let res = await send(payload, endpoint);
  // unreachable (and not an orphaned-context reload) → launch + wait for the heartbeat + retry once.
  if (res?.status === 0 && !/reload/i.test(res.error || "")) {
    toast(STAGE.launching, true, true, true);
    const launched = await launchViewer();
    if (!launched.ok) {
      return { status: 0, error: `couldn't launch viewer — ${launched.err}` };
    }
    toast(STAGE.waiting, true, true, true);
    if (!(await waitForViewer(15000))) {
      return { status: 0, error: "viewer didn't come up" };
    }
    res = await send(payload, endpoint);
  }
  // up but cold: stack-open timed out building the worktree (504). It's warm now — wait + retry.
  for (let i = 0; i < 2 && res?.status === 504; i++) {
    toast(STAGE.warming, true, true, true);
    await sleep(1200 + i * 800);
    res = await send(payload, endpoint);
  }
  return res;
}

function reset(btn, label) {
  btn.textContent = label;
  btn.disabled = false;
  btn.classList.remove("gh-nvim-ok", "gh-nvim-err");
}

async function fire(btn, payload, label, okText, target) {
  btn.disabled = true;
  btn.textContent = "…";
  const res = await openWithRecovery(payload, undefined, target || "nvim");
  const ok = resultToast(res, target || "nvim");
  btn.classList.add(ok ? "gh-nvim-ok" : "gh-nvim-err");
  btn.textContent = ok ? okText(res.body) : "✗";
  btn.title = ok ? `opened ${res.body.branch}` : `failed: ${reason(res)}`;
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
    const { payload, short, full } = await nvimRequest(pr);
    fire(nvimBtn, payload, "→ nvim", () => `✓ ${short}`, full);
  });

  const viewer = document.createElement("button");
  viewer.className = "gh-nvim-fab-btn";
  viewer.textContent = "→ viewer";
  viewer.title = "Import + open this PR in the forest viewer";
  viewer.addEventListener("click", async () => {
    viewer.disabled = true;
    viewer.textContent = "…";
    const res = await openWithRecovery({ number: pr.number, repo: pr.repo }, undefined, `viewer #${pr.number}`);
    const ok = res?.status === 200 && res.body?.ok;
    if (ok) {
      // backend owns the route; fall back to the standalone shape if it predates `path`
      const route = res.body.path || `/branch/${res.body.branch}`;
      window.open(`${VIEWER_URL}${route}`, "_blank");
    }
    viewer.classList.add(ok ? "gh-nvim-ok" : "gh-nvim-err");
    viewer.textContent = ok ? "✓" : "✗";
    viewer.title = ok ? `opened ${res.body.branch}` : `failed: ${reason(res)}`;
    setTimeout(() => reset(viewer, "→ viewer"), 4000);
  });

  box.append(nvimBtn, viewer);
  decorateForest(box, pr, viewer);
  return box;
}

// forest chip: which forest this PR's branch belongs to, straight from the same git config the
// viewer reads. A local branch's chip IS the viewer link, so the redundant → viewer button is
// dropped (it stays for non-local PRs, where it imports first). Orphaned children (a squash/amend
// knocks them off the tip) are flagged in the tooltip only — fixing them lives in the viewer
// (Restack), not here; the chip is the one-click route to it.
async function decorateForest(box, pr, viewerBtn) {
  const res = await send({ number: pr.number, repo: pr.repo }, "/pr-forest");
  const info = res?.status === 200 && res.body?.ok ? res.body : null;
  if (!info?.branch) {
    return;
  }
  const chip = document.createElement("a");
  chip.className = "gh-nvim-forest-chip";
  chip.textContent = `⧉ ${info.project || info.branch}`;
  chip.href = `${VIEWER_URL}${info.route}`;
  chip.target = "_blank";
  const kids = info.children || [];
  chip.title = `${info.branch}${info.project ? ` · forest ${info.project}` : ""}` +
    (kids.length ? `\nchildren: ${kids.map((c) => `${c.branch}${c.seated ? "" : " (orphaned)"}`).join(", ")}` : "");
  viewerBtn.remove();
  box.append(chip);
}

function toast(text, ok, sticky, working) {
  let el = document.getElementById("gh-nvim-toast");
  if (!el) {
    el = document.createElement("div");
    el.id = "gh-nvim-toast";
    document.body.appendChild(el);
  }
  el.textContent = text;
  el.classList.toggle("gh-nvim-err", !ok);
  el.classList.toggle("gh-nvim-working", !!working);   // blue + pulsing dot while a recovery stage runs
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
  if (!table) {
    return;
  }
  const path = table.getAttribute("aria-label").replace(/^Diff for: /, "");
  const line = cell.getAttribute("data-line-number");
  const full = `${path}:${line}`;
  const pr = parsePr();
  if (pr) {
    e.preventDefault();
    e.stopPropagation();
    resultToast(await openWithRecovery({ number: pr.number, repo: pr.repo, path, line }, undefined, full), full);
    return;
  }
  const commit = parseCommit();
  if (commit) {
    e.preventDefault();
    e.stopPropagation();
    resultToast(await openWithRecovery({ repo: commit.repo, path, line }, "/open-blob", full), full);
  }
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
    fire(btn, { number: pr.number, repo: pr.repo, path, line: 1 }, "nvim", () => "✓", path);
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
  void warmDiffHashCache();
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
// "o" (no modifiers, not while typing) → on a PR: the selected file+line, else the gm Diffview;
// on a file blob view: that file at #L<n> in the working checkout.
async function onOpenKey(e) {
  if (e.key !== "o" || e.altKey || e.metaKey || e.ctrlKey) {
    return;
  }
  const t = e.target;
  if (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)) {
    return;
  }
  const pr = parsePr();
  if (pr) {
    e.preventDefault();
    e.stopPropagation();
    const { payload, full } = await nvimRequest(pr);
    resultToast(await openWithRecovery(payload, undefined, full), full);
    return;
  }
  const commit = parseCommit();
  if (commit) {
    // no PR, no gm view — only act if a diff line is selected (#diff-<hash>R<n>); resolve it to the
    // file+line and open in the working checkout.
    const sel = await selectedLine();
    if (!sel) {
      return;
    }
    e.preventDefault();
    e.stopPropagation();
    const full = `${sel.path}:${sel.line}`;
    resultToast(
      await openWithRecovery({ repo: commit.repo, path: sel.path, line: sel.line }, "/open-blob", full),
      full
    );
    return;
  }
  const blob = parseBlob();
  if (!blob) {
    return;
  }
  e.preventDefault();
  e.stopPropagation();
  const full = `${blob.path}:${blob.line}`;
  resultToast(await openWithRecovery({ repo: blob.repo, ref: blob.ref, path: blob.path, line: blob.line }, "/open-blob", full), full);
}

document.addEventListener("click", onLineClick, true);
document.addEventListener("keydown", altToggle, true);
document.addEventListener("keyup", altToggle, true);
document.addEventListener("keydown", onOpenKey, true);
window.addEventListener("blur", () => document.body.classList.remove("gh-nvim-alt"));
