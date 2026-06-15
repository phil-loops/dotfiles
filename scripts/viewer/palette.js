// ── CMD+K command palette ──────────────────────────────
// Self-contained accessory: drives selection via the shared `active`/`render`,
// reads NODES/MODEL, runs safe ops in-browser and hands the heavy/interactive op
// (restack) off to the terminal (copies the command, where claude can escalate).
// Concatenated LAST and uses capture-phase keys so it pre-empts detail.js's
// single-key shortcuts while the palette is open.
(function () {
  const REPO = "phil-loops/loops";
  const proj = () => (MODEL && (MODEL.project || MODEL.leaf)) || "";
  const ghTree = (b) =>
    `https://github.com/${REPO}/tree/${encodeURIComponent(b)}`;
  let PRS = null;
  const loadPRs = () =>
    fetch("/prs")
      .then((r) => (r.ok ? r.json() : {}))
      .then((p) => (PRS = p || {}))
      .catch(() => (PRS = {}));
  const copy = (c) => {
    try {
      navigator.clipboard.writeText(c);
    } catch (e) {}
  };

  const ov = el("div", "cmdk");
  ov.id = "cmdk";
  ov.innerHTML = `<div class="cmdk-box">
    <input class="cmdk-in" placeholder="run a command or jump to a branch…" spellcheck="false" autocomplete="off">
    <ul class="cmdk-list"></ul>
    <div class="cmdk-hint">↑↓ move · ↵ run · esc close</div></div>`;
  document.body.appendChild(ov);
  const input = ov.querySelector(".cmdk-in");
  const list = ov.querySelector(".cmdk-list");
  let items = [],
    sel = 0,
    isOpen = false;

  // scope-aware command set: forest ops always, node ops when a branch is
  // selected, plus a fuzzy-jump entry per node.
  function commands() {
    const c = [];
    const node = typeof active === "string" && active ? active : "";
    c.push({
      k: "forest",
      label: "⟳  Restack forest onto fresh main (claude-driven)",
      run() {
        const cmd = `loops stack restack ${proj()}`;
        copy(cmd);
        toast(
          `copied — run in terminal (preview with <b>--plan</b> first):<br><b>${cmd}</b>`
        );
      },
    });
    c.push({
      k: "forest",
      label: "⎇  Check PRs against main",
      async run() {
        await loadPRs();
        checkPRs();
      },
    });
    c.push({
      k: "forest",
      label: "↪  Jump to current checkout (HEAD)",
      async run() {
        let b = "";
        try {
          b = ((await (await fetch("/head")).json()).branch || "").trim();
        } catch (e) {}
        if (!b) {
          toast("couldn’t read the checkout’s branch");
          return;
        }
        // already in the loaded forest → select in place, no reload
        const here = (NODES || []).find((x) => x.branch === b);
        if (here) {
          active = here.id;
          render();
          toast(`↪ <b>${b.split("/").pop()}</b> (current checkout)`);
          return;
        }
        // else (picker, or a different project): the model expands from ANY member
        // branch, so look up the forest that contains it and navigate there, selecting
        // the node via the URL hash. If it's in no forest, say so.
        let m = null;
        try {
          m = await (await fetch("/model?branch=" + encodeURIComponent(b))).json();
        } catch (e) {}
        if (!m || !m.nodes || !m.nodes[b]) {
          toast(`checkout is on <b>${b}</b> — not in any forest`);
          return;
        }
        location.href =
          location.pathname +
          "?branch=" + encodeURIComponent(b) +
          "#node=" + encodeURIComponent(b);
      },
    });
    if (node) {
      const s = node.split("/").pop();
      c.push({
        k: "node",
        label: `↗  Open on GitHub · ${s}`,
        async run() {
          await loadPRs();
          window.open((PRS && PRS[node] && PRS[node].url) || ghTree(node), "_blank");
        },
      });
      c.push({
        k: "node",
        label: `✦  Bless · ${s}`,
        run() {
          doBless(node, ".");
        },
      });
    }
    (NODES || []).forEach((n) =>
      c.push({
        k: "jump",
        label: `→  ${n.branch}`,
        run() {
          active = n.id;
          render();
        },
      })
    );
    return c;
  }

  function checkPRs() {
    const bs = (NODES || []).map((n) => n.branch);
    const m = [],
      x = [],
      z = [];
    bs.forEach((b) => {
      const p = PRS && PRS[b];
      if (!p) z.push(b);
      else if (p.toMain) m.push(b);
      else x.push(b);
    });
    toast(
      `PRs → main: <b>${m.length}</b> · stray base: <b>${x.length}</b> · no PR: <b>${z.length}</b>`
    );
  }

  const fz = (q, s) => {
    q = q.toLowerCase();
    s = s.toLowerCase();
    let i = 0;
    for (let j = 0; j < s.length && i < q.length; j++) if (s[j] === q[i]) i++;
    return i === q.length;
  };
  function refilter() {
    const q = input.value.trim();
    const all = commands();
    items = q ? all.filter((c) => fz(q, c.label)) : all;
    if (sel >= items.length) sel = 0;
    paint();
  }
  function paint() {
    list.innerHTML = items.length
      ? items
          .map(
            (c, i) =>
              `<li class="cmdk-it k-${c.k}${i === sel ? " on" : ""}" data-i="${i}">${c.label}</li>`
          )
          .join("")
      : `<li class="cmdk-empty">no matches</li>`;
    list.querySelectorAll(".cmdk-it").forEach((li) => {
      const i = +li.dataset.i;
      li.onmousemove = () => {
        if (sel !== i) {
          sel = i;
          paint();
        }
      };
      li.onclick = () => runItem(i);
    });
    const on = list.querySelector(".on");
    if (on) on.scrollIntoView({ block: "nearest" });
  }
  function runItem(i) {
    const c = items[i];
    if (!c) return;
    close();
    c.run();
  }
  function openP() {
    isOpen = true;
    ov.classList.add("on");
    input.value = "";
    sel = 0;
    refilter();
    setTimeout(() => input.focus(), 0);
  }
  function close() {
    isOpen = false;
    ov.classList.remove("on");
  }

  input.addEventListener("input", refilter);
  ov.addEventListener("mousedown", (e) => {
    if (e.target === ov) close();
  });
  addEventListener(
    "keydown",
    (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        e.stopPropagation();
        isOpen ? close() : openP();
        return;
      }
      if (!isOpen) return;
      e.stopPropagation(); // pre-empt detail.js single-key shortcuts while typing
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        sel = Math.min(sel + 1, items.length - 1);
        paint();
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        sel = Math.max(sel - 1, 0);
        paint();
      } else if (e.key === "Enter") {
        e.preventDefault();
        runItem(sel);
      }
    },
    true // capture
  );
})();
