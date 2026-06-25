const FILE_BTN = "gh-nvim-file-btn";

function parsePr() {
  const m = location.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
  if (!m) {
    return null;
  }
  return { repo: `${m[1]}/${m[2]}`, number: Number(m[3]) };
}

function send(payload) {
  return new Promise((resolve) =>
    chrome.runtime.sendMessage({ type: "from-github", payload }, resolve),
  );
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
  const btn = document.createElement("button");
  btn.id = "gh-nvim-fab";
  btn.textContent = "→ nvim";
  btn.title = `Import PR #${pr.number} into the forest viewer`;
  btn.addEventListener("click", () =>
    fire(btn, { number: pr.number, repo: pr.repo }, "→ nvim", (b) => `✓ ${b.branch}`),
  );
  return btn;
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
