// Injected into every HTML page a loops-preview proxy serves. Draws a small pill in the
// bottom-right corner; click it (or Ctrl+`) for a live tail of the preview's server log
// and setup log, streamed over SSE from /__preview/log. Lives in a shadow root so the
// app's CSS never sees it. Served by loops-preview-proxy.mjs; edits take effect on reload.
(() => {
  if (window.__loopsPreviewBadge) return;
  window.__loopsPreviewBadge = true;

  const BASE = "/__preview";
  const MAX_ENTRIES = 2000;
  const NOISE = [
    /cf-connecting-ip absent/,
    /\/api\/trpc\/jobStatus\.status\?/,
    /\/api\/trpc\/bulkAudienceAction\.getCurrentActions\?/,
    /\/api\/trpc\/notifications?\./,
  ];
  const ACCESS = /^ ?(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) \S+ \d{3} in /;
  const ERROR = /(^|\W)(Error|TypeError|RangeError|ReferenceError|PrismaClient\w+Error)\b|⨯|\bP\d{4}\b| 5\d\d in |"level":(50|60|"error"|"fatal")|\bECONNREFUSED\b|\bFATAL\b/;
  const WARN = /"level":(40|"warn")|\bwarn(ing)?\b| 4\d\d in |⚠/i;
  const CONTINUATION = /^(\s+|at |\d+ \|| *[>|] |\.\.\.|\}|\]|\)|✗|▸)/;

  const store = (() => {
    const key = "loops-preview-badge";
    let state = { open: false, height: 40, noise: false, access: true };
    try { Object.assign(state, JSON.parse(localStorage.getItem(key) || "{}")); } catch {}
    return {
      get: () => state,
      set: (patch) => { Object.assign(state, patch); try { localStorage.setItem(key, JSON.stringify(state)); } catch {} },
    };
  })();

  const host = document.createElement("loops-preview-badge");
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
<style>
  :host { all: initial; position: fixed; right: 12px; bottom: 12px; z-index: 2147483000;
    font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--fg);
    --bg: #fbfbfa; --fg: #1d1d1b; --mute: #7d7d78; --line: #e6e6e2; --pill: #fff; --err: #c8332f; --warn: #a56c00; --ok: #2b7a3d; --brand: #3b6cf6; --sel: #eef2ff; }
  @media (prefers-color-scheme: dark) { :host {
    --bg: #17181a; --fg: #e8e8e4; --mute: #8a8a85; --line: #2a2b2e; --pill: #202124; --err: #ff6b62; --warn: #f0b429; --ok: #5ccc7a; --brand: #7c9cff; --sel: #1f2436; } }
  * { box-sizing: border-box; }
  button { font: inherit; color: inherit; background: none; border: 1px solid var(--line); border-radius: 6px; padding: 2px 8px; cursor: pointer; }
  button:hover { background: var(--sel); }
  button[aria-pressed="true"] { background: var(--sel); border-color: var(--brand); }
  .pill { display: flex; align-items: center; gap: 8px; padding: 6px 10px 6px 12px; border-radius: 999px;
    background: var(--pill); border: 1px solid var(--line); box-shadow: 0 2px 10px rgba(0,0,0,.12); cursor: pointer; user-select: none; }
  .pill:hover { border-color: var(--brand); }
  .pill .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--ok); }
  .pill.booting .dot { background: var(--warn); animation: blink 1.2s infinite; }
  .pill.down .dot { background: var(--err); }
  .pill .count { color: #fff; background: var(--err); border-radius: 999px; padding: 0 6px; font-weight: 600; }
  .pill .count:empty { display: none; }
  @keyframes blink { 50% { opacity: .3; } }
  .panel { display: none; position: fixed; left: 0; right: 0; bottom: 0; height: 40vh; min-height: 140px;
    background: var(--bg); color: var(--fg); border-top: 1px solid var(--line); box-shadow: 0 -6px 24px rgba(0,0,0,.18); flex-direction: column; }
  .panel.open { display: flex; }
  .grip { height: 5px; cursor: ns-resize; background: transparent; }
  .grip:hover { background: var(--sel); }
  .bar { display: flex; align-items: center; gap: 8px; padding: 4px 10px 6px; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
  .bar .title { font-weight: 600; }
  .bar .title span { color: var(--mute); font-weight: 400; }
  .bar input { flex: 1; min-width: 140px; font: inherit; color: inherit; background: var(--pill); border: 1px solid var(--line); border-radius: 6px; padding: 2px 8px; outline: none; }
  .bar input:focus { border-color: var(--brand); }
  .bar a { color: var(--brand); text-decoration: none; border: 1px solid var(--line); border-radius: 6px; padding: 2px 8px; }
  .bar a:hover { background: var(--sel); }
  .bar .x { border: none; font-size: 14px; padding: 0 6px; }
  .lines { flex: 1; overflow: auto; padding: 4px 0 8px; white-space: pre-wrap; word-break: break-word; }
  .e { padding: 1px 10px; border-left: 3px solid transparent; }
  .e .t { color: var(--mute); margin-right: 8px; }
  .e.error { border-left-color: var(--err); color: var(--err); }
  .e.warn { border-left-color: var(--warn); }
  .e.access { color: var(--mute); }
  .e.browser { color: var(--brand); }
  .e.setup { color: var(--mute); font-style: italic; }
  .e.setup.error { color: var(--err); font-style: normal; }
  .e .more { color: var(--mute); cursor: pointer; margin-left: 8px; text-decoration: underline dotted; }
  .e .detail { display: none; color: var(--fg); opacity: .85; margin-top: 2px; }
  .e.expanded .detail { display: block; }
  .jump { position: absolute; right: 16px; bottom: 12px; display: none; background: var(--pill); }
  .jump.show { display: block; }
  .empty { padding: 20px; color: var(--mute); text-align: center; }
</style>
<div class="pill" part="pill" title="Preview server log (Ctrl+\`)">
  <span class="dot"></span><span class="label">preview</span><span class="count"></span>
</div>
<div class="panel" role="region" aria-label="preview server log">
  <div class="grip"></div>
  <div class="bar">
    <span class="title"><b class="name"></b> <span class="meta"></span></span>
    <input class="filter" placeholder="filter (regex)" spellcheck="false" />
    <button class="noise" title="show the polling + IP-resolution chatter">noise</button>
    <button class="access" title="show 2xx/3xx request lines">requests</button>
    <button class="pause" title="stop following new lines">pause</button>
    <button class="clear" title="forget what has been shown so far">clear</button>
    <a class="grafana" target="_blank" rel="noopener" hidden>grafana ↗</a>
    <button class="x" title="close (Esc)">×</button>
  </div>
  <div class="lines"></div>
  <button class="jump">↓ new lines</button>
</div>`;

  const $ = (sel) => root.querySelector(sel);
  const pill = $(".pill"), panel = $(".panel"), lines = $(".lines"), jump = $(".jump");
  const countEl = $(".count"), labelEl = $(".label"), nameEl = $(".name"), metaEl = $(".meta"), grafanaEl = $(".grafana");
  const filterEl = $(".filter"), noiseBtn = $(".noise"), accessBtn = $(".access"), pauseBtn = $(".pause");

  const entries = [];
  let unseenErrors = 0, paused = false, filter = null, pinnedToBottom = true;

  const classify = (text, src) => {
    if (src === "setup") return /^✗/.test(text) ? "setup error" : "setup";
    if (text.startsWith("[browser]")) return ERROR.test(text) ? "browser error" : "browser";
    if (ERROR.test(text)) return "error";
    if (WARN.test(text)) return "warn";
    if (ACCESS.test(text)) return "access";
    return "";
  };
  const isNoise = (text) => NOISE.some((re) => re.test(text));

  const pino = (text) => {
    if (!text.startsWith("{")) return null;
    try {
      const j = JSON.parse(text);
      if (typeof j.msg !== "string") return null;
      const lvl = typeof j.level === "number" ? ({ 10: "trace", 20: "debug", 30: "info", 40: "warn", 50: "error", 60: "fatal" })[j.level] : j.level;
      const extra = j.err?.type ? ` [${j.err.type}]` : "";
      const page = j.page || j.path || j.url ? ` ${j.page || j.path || j.url}` : "";
      return { lvl: lvl || "", text: `${lvl ? lvl + " " : ""}${j.msg}${extra}${page}`, stack: j.err?.stack || j.stack || "" };
    } catch { return null; }
  };

  const fmtTime = (ms) => {
    const d = new Date(ms);
    return d.toTimeString().slice(0, 8);
  };

  const render = (entry) => {
    const el = document.createElement("div");
    el.className = "e " + entry.cls;
    const t = document.createElement("span");
    t.className = "t"; t.textContent = fmtTime(entry.time);
    el.appendChild(t);
    el.appendChild(document.createTextNode(entry.text));
    if (entry.detail.length) {
      const more = document.createElement("span");
      more.className = "more"; more.textContent = `▸ ${entry.detail.length} more`;
      more.onclick = () => { el.classList.toggle("expanded"); more.textContent = el.classList.contains("expanded") ? "▾ less" : `▸ ${entry.detail.length} more`; };
      el.appendChild(more);
      const d = document.createElement("div");
      d.className = "detail"; d.textContent = entry.detail.join("\n");
      el.appendChild(d);
    }
    el.title = entry.raw;
    entry.el = el;
    return el;
  };

  const visible = (entry) => {
    if (entry.noise && !store.get().noise) return false;
    if (entry.cls === "access" && !store.get().access) return false;
    if (filter && !filter.test(entry.text + "\n" + entry.detail.join("\n"))) return false;
    return true;
  };

  const repaint = () => {
    lines.textContent = "";
    const frag = document.createDocumentFragment();
    let n = 0;
    for (const e of entries) if (visible(e)) { frag.appendChild(e.el || render(e)); n++; }
    if (!n) { const d = document.createElement("div"); d.className = "empty"; d.textContent = entries.length ? "nothing matches" : "waiting for log lines…"; frag.appendChild(d); }
    lines.appendChild(frag);
    lines.scrollTop = lines.scrollHeight;
    pinnedToBottom = true; jump.classList.remove("show");
  };

  let last = null;
  const push = (text, src, time) => {
    if (!text.trim()) return;
    const p = src === "server" ? pino(text) : null;
    const shown = p ? p.text : text;
    if (last && last.src === src && !p && CONTINUATION.test(text) && !ACCESS.test(text) && Date.now() - last.time < 60_000) {
      last.detail.push(text);
      last.raw += "\n" + text;
      if (last.el) { const fresh = render(last); last.el.replaceWith(fresh); }
      return;
    }
    const cls = p ? (p.lvl === "error" || p.lvl === "fatal" ? "error" : p.lvl === "warn" ? "warn" : "") : classify(text, src);
    const entry = { text: shown, raw: text, cls: `${cls} ${src === "setup" ? "setup" : ""}`.trim(), src, time: time || Date.now(), detail: p?.stack ? p.stack.split("\n").slice(1) : [], noise: isNoise(text) };
    entries.push(entry); last = entry;
    if (entries.length > MAX_ENTRIES) { const gone = entries.shift(); gone.el?.remove(); }
    if (cls.includes("error") && !panel.classList.contains("open")) { unseenErrors++; countEl.textContent = String(unseenErrors); }
    if (paused || !visible(entry)) return;
    if (lines.querySelector(".empty")) lines.textContent = "";
    lines.appendChild(render(entry));
    if (pinnedToBottom) lines.scrollTop = lines.scrollHeight; else jump.classList.add("show");
  };

  lines.addEventListener("scroll", () => {
    pinnedToBottom = lines.scrollHeight - lines.scrollTop - lines.clientHeight < 24;
    if (pinnedToBottom) jump.classList.remove("show");
  });
  jump.onclick = () => { lines.scrollTop = lines.scrollHeight; };

  const setOpen = (open) => {
    panel.classList.toggle("open", open);
    pill.style.display = open ? "none" : "";
    store.set({ open });
    if (open) { unseenErrors = 0; countEl.textContent = ""; panel.style.height = store.get().height + "vh"; repaint(); filterEl.focus({ preventScroll: true }); }
  };
  pill.onclick = () => setOpen(true);
  $(".x").onclick = () => setOpen(false);
  window.addEventListener("keydown", (e) => {
    if (e.key === "`" && e.ctrlKey) { e.preventDefault(); setOpen(!panel.classList.contains("open")); }
    else if (e.key === "Escape" && panel.classList.contains("open") && root.activeElement !== filterEl) setOpen(false);
  });
  filterEl.addEventListener("keydown", (e) => { if (e.key === "Escape") { filterEl.value = ""; filter = null; repaint(); filterEl.blur(); } });

  const syncToggles = () => {
    noiseBtn.setAttribute("aria-pressed", String(store.get().noise));
    accessBtn.setAttribute("aria-pressed", String(store.get().access));
    pauseBtn.setAttribute("aria-pressed", String(paused));
    pauseBtn.textContent = paused ? "resume" : "pause";
  };
  noiseBtn.onclick = () => { store.set({ noise: !store.get().noise }); syncToggles(); repaint(); };
  accessBtn.onclick = () => { store.set({ access: !store.get().access }); syncToggles(); repaint(); };
  pauseBtn.onclick = () => { paused = !paused; syncToggles(); if (!paused) repaint(); };
  $(".clear").onclick = () => { entries.length = 0; last = null; repaint(); };
  filterEl.addEventListener("input", () => {
    try { filter = filterEl.value ? new RegExp(filterEl.value, "i") : null; filterEl.style.borderColor = ""; }
    catch { filterEl.style.borderColor = "var(--err)"; return; }
    repaint();
  });
  syncToggles();

  const grip = $(".grip");
  grip.addEventListener("pointerdown", (e) => {
    const startY = e.clientY, startH = panel.getBoundingClientRect().height;
    const move = (ev) => { const h = Math.max(140, startH + (startY - ev.clientY)); panel.style.height = h + "px"; };
    const up = () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up); store.set({ height: Math.round(panel.getBoundingClientRect().height / window.innerHeight * 100) }); };
    window.addEventListener("pointermove", move); window.addEventListener("pointerup", up);
  });

  let meta = null;
  const applyMeta = (m) => {
    meta = m;
    labelEl.textContent = `${m.name} · :${m.port}`;
    nameEl.textContent = m.name;
    metaEl.textContent = `${m.branch === m.name ? "" : m.branch + " · "}:${m.port}${m.upstreamUp ? "" : m.upstreamDied ? " · next dev exited" : " · booting"}`;
    pill.classList.toggle("booting", !m.upstreamUp && !m.upstreamDied);
    pill.classList.toggle("down", !!m.upstreamDied);
    if (m.grafana) { grafanaEl.href = m.grafana; grafanaEl.hidden = false; } else grafanaEl.hidden = true;
    if (document.documentElement.dataset.previewBoot === "1" && m.upstreamUp) location.reload();
  };
  const pollMeta = async () => {
    try { applyMeta(await (await fetch(`${BASE}/meta`, { cache: "no-store" })).json()); } catch {}
  };

  const connect = () => {
    const es = new EventSource(`${BASE}/log?tail=300`);
    es.addEventListener("init", (ev) => {
      const { lines: init, meta: m } = JSON.parse(ev.data);
      if (m) applyMeta(m);
      entries.length = 0; last = null;
      for (const l of init) push(l.text, l.src, l.time);
      unseenErrors = 0; countEl.textContent = "";
      if (panel.classList.contains("open")) repaint();
    });
    es.addEventListener("line", (ev) => { const l = JSON.parse(ev.data); push(l.text, l.src, l.time); });
    es.addEventListener("reset", () => { entries.length = 0; last = null; if (panel.classList.contains("open")) repaint(); });
    es.addEventListener("meta", (ev) => applyMeta(JSON.parse(ev.data)));
    es.onerror = () => { es.close(); setTimeout(connect, 1500); };
  };

  document.documentElement.appendChild(host);
  connect();
  pollMeta(); setInterval(pollMeta, 5000);
  if (store.get().open || document.documentElement.dataset.previewBoot === "1") setOpen(true);
})();
