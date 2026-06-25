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

function flash(btn, text, cls, restore) {
  btn.textContent = text;
  btn.classList.remove("gh-nvim-ok", "gh-nvim-err");
  if (cls) {
    btn.classList.add(cls);
  }
  setTimeout(() => {
    btn.textContent = restore;
    btn.disabled = false;
    btn.classList.remove("gh-nvim-ok", "gh-nvim-err");
  }, 4000);
}

function makeButton(pr) {
  const btn = document.createElement("button");
  btn.id = "gh-nvim-fab";
  btn.textContent = "→ nvim";
  btn.title = `Import PR #${pr.number} into the forest viewer`;
  btn.addEventListener("click", async () => {
    btn.disabled = true;
    btn.textContent = "…importing";
    const res = await send({ number: pr.number, repo: pr.repo });
    const ok = res?.status === 200 && res.body?.ok;
    const detail = ok ? `✓ ${res.body.branch}` : `✗ ${res?.body?.err || res?.error || res?.status || "failed"}`;
    flash(btn, detail, ok ? "gh-nvim-ok" : "gh-nvim-err", "→ nvim");
  });
  return btn;
}

function tick() {
  const pr = parsePr();
  const btn = document.getElementById("gh-nvim-fab");
  if (pr && !btn) {
    document.body.appendChild(makeButton(pr));
  } else if (!pr && btn) {
    btn.remove();
  }
}

tick();
setInterval(tick, 2000);
