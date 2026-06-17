import {
  createSignal,
  createMemo,
  createEffect,
  Show,
  For,
  onCleanup,
} from "solid-js";
import {
  createQuery,
  createMutation,
  useQueryClient,
} from "@tanstack/solid-query";
import * as Diff2Html from "diff2html";
import { fetchJSON } from "./api";

// ── url ──────────────────────────────────────────────────────────────
// ?branch=<project> chooses a forest; #node=<branch> the node you're reading.
// No project → the home (your ledger summary). Project, no node → its tip.
function readUrl() {
  const q = new URLSearchParams(location.search);
  const h = new URLSearchParams(location.hash.replace(/^#/, ""));
  return { project: q.get("branch") || "", node: h.get("node") || "" };
}
const leaf = (s) => (s || "").split("/").pop();
const isBlessed = (f) => f.status === "clean" || f.status === "blessed";

function flattenForest(model) {
  if (!model) return [];
  if (model.nodes) {
    const out = [],
      seen = new Set();
    const walk = (b, d) => {
      if (seen.has(b)) return;
      seen.add(b);
      const n = model.nodes[b];
      if (!n) return;
      out.push({ ...n, id: b, depth: d });
      (n.children || []).forEach((c) => walk(c, d + 1));
    };
    (model.roots || []).forEach((r) => walk(r, 0));
    Object.keys(model.nodes).forEach((b) => !seen.has(b) && walk(b, 0));
    return out;
  }
  return (model.links || []).map((l) => ({ ...l, id: l.branch, depth: 0 }));
}
function lumen(n) {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// ── router ───────────────────────────────────────────────────────────
export default function App() {
  const [url, setUrl] = createSignal(readUrl());
  const sync = () => setUrl(readUrl());
  window.addEventListener("hashchange", sync);
  window.addEventListener("popstate", sync);

  const qc = useQueryClient();
  const es = new EventSource("/events");
  es.addEventListener("update", () => {
    qc.invalidateQueries({ queryKey: ["node"] });
    qc.invalidateQueries({ queryKey: ["model"] });
    qc.invalidateQueries({ queryKey: ["projects"] });
  });
  onCleanup(() => es.close());

  return (
    <Show when={url().project} fallback={<Home />}>
      <NodeDetail url={url} />
    </Show>
  );
}

// ── home: the ledger summary ─────────────────────────────────────────
function Home() {
  const prs = createQuery(() => ({
    queryKey: ["myprs"],
    queryFn: () => fetchJSON("/myprs"),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => fetchJSON("/projects"),
  }));
  const checkOrigin = createMutation(() => ({
    mutationFn: () => fetch("/check-origin", { method: "POST", body: "{}" }).then((r) => r.json()),
    onSuccess: () => {
      prs.refetch();
      projects.refetch();
    },
  }));

  // ── restack: two-click arm → run (background) → poll → parked? hand to Claude ──
  const [armed, setArmed] = createSignal(null); // project name (or "__all__") awaiting confirm
  const [running, setRunning] = createSignal(null); // project name (or "__all__") restacking now
  const [parked, setParked] = createSignal(null); // { project, current, reason } on a conflict
  let armT;
  const post = (url, body) =>
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  const start = (key) => {
    setParked(null);
    const body =
      key === "__all__"
        ? { projects: (projects.data || []).filter((p) => p.behind > 0).map((p) => p.name) }
        : { project: key };
    post(key === "__all__" ? "/restack-all" : "/restack", body).then((r) => {
      if (r.ok) setRunning(key);
    });
  };
  const arm = (key) => {
    if (armed() === key) {
      clearTimeout(armT);
      setArmed(null);
      start(key);
      return;
    }
    setArmed(key);
    clearTimeout(armT);
    armT = setTimeout(() => setArmed(null), 3000);
  };
  const status = createQuery(() => ({
    queryKey: ["restack-status", running()],
    queryFn: () =>
      fetchJSON(
        "/restack-status" +
          (running() && running() !== "__all__"
            ? "?project=" + encodeURIComponent(running())
            : "")
      ),
    enabled: !!running(),
    refetchInterval: (q) => (q.state.data?.running === false ? false : 2500),
  }));
  createEffect(() => {
    if (!running()) return;
    const d = status.data;
    if (!d || d.running) return; // still churning through the topo walk
    if (d.paused) setParked({ project: d.project, current: d.current, reason: d.reason });
    setRunning(null);
    projects.refetch();
  });
  const resolve = (project) =>
    post("/restack-resolve", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setRunning(project); // re-poll while Claude resolves + resumes
      }
    });

  const byProject = createMemo(() => {
    const m = new Map();
    for (const p of prs.data || []) {
      const k = p.project || "—";
      if (!m.has(k)) m.set(k, []);
      m.get(k).push(p);
    }
    return [...m.entries()];
  });

  const review = (r) =>
    r === "APPROVED" ? ["✓", "ok"] : r === "CHANGES_REQUESTED" ? ["▲", "chg"] : ["•", "req"];

  return (
    <div class="home">
      <header class="home-head">
        <div class="brand big">
          <span class="brand-mark">✦</span> blessed
        </div>
        <button
          class="origin-btn"
          disabled={checkOrigin.isPending}
          onClick={() => checkOrigin.mutate()}
        >
          {checkOrigin.isPending ? "checking…" : "↻ check origin"}
        </button>
      </header>

      <Show when={(prs.data || []).length}>
        <section>
          <h2 class="eyebrow">your open PRs</h2>
          <For each={byProject()}>
            {([proj, list]) => (
              <div class="pr-group">
                <div class="pr-project">{proj}</div>
                <For each={list}>
                  {(p) => {
                    const [mark, cls] = review(p.review);
                    return (
                      <a
                        class="pr-row"
                        href={p.project ? `?branch=${encodeURIComponent(p.project)}#node=${encodeURIComponent(p.branch)}` : p.url}
                        target={p.project ? "_self" : "_blank"}
                      >
                        <span class="pr-num">#{p.num}</span>
                        <span class="pr-title">{p.title}</span>
                        {p.draft && <span class="pr-draft">draft</span>}
                        <span class={`pr-rev ${cls}`}>{mark}</span>
                      </a>
                    );
                  }}
                </For>
              </div>
            )}
          </For>
        </section>
      </Show>

      <section>
        <div class="eyebrow-row">
          <h2 class="eyebrow">forests</h2>
          <Show when={(projects.data || []).some((p) => p.behind > 0)}>
            <button
              class="restack-all"
              classList={{ armed: armed() === "__all__", running: running() === "__all__" }}
              onClick={() => running() !== "__all__" && arm("__all__")}
            >
              {running() === "__all__"
                ? "⤳ restacking all…"
                : armed() === "__all__"
                  ? "restack all behind?"
                  : `⟳ restack all ${(projects.data || []).filter((p) => p.behind > 0).length} behind`}
            </button>
          </Show>
        </div>
        <Show when={(projects.data || []).length} fallback={<p class="loading">no forests configured</p>}>
          <For each={projects.data}>
            {(p) => {
              const busy = () => running() === p.name || running() === "__all__";
              const stuck = () => parked()?.project === p.name;
              return (
                <a
                  class="forest-row"
                  classList={{ parked: stuck() }}
                  href={`?branch=${encodeURIComponent(p.name)}`}
                >
                  <span
                    class={`forest-dot ${stuck() ? "parked" : p.behind > 0 ? "behind" : "fresh"}`}
                  />
                  <span class="forest-name">{p.name}</span>
                  <span class="forest-meta">
                    {p.branches} {p.branches === 1 ? "node" : "nodes"}
                  </span>
                  <Show
                    when={stuck()}
                    fallback={
                      <Show
                        when={p.behind > 0}
                        fallback={<span class="forest-fresh fresh">✦ fresh</span>}
                      >
                        <button
                          class="forest-restack"
                          classList={{ armed: armed() === p.name, running: busy() }}
                          onClick={(e) => {
                            e.preventDefault();
                            e.stopPropagation();
                            if (!busy()) arm(p.name);
                          }}
                        >
                          {busy()
                            ? "⤳ restacking…"
                            : armed() === p.name
                              ? "restack?"
                              : `⟳ ${p.behind} behind`}
                        </button>
                      </Show>
                    }
                  >
                    <button
                      class="forest-resolve"
                      title={parked()?.reason || ""}
                      onClick={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        resolve(p.name);
                      }}
                    >
                      ⚠ resolve {leaf(parked()?.current || p.name)}
                    </button>
                  </Show>
                </a>
              );
            }}
          </For>
        </Show>
      </section>
    </div>
  );
}

// ── forest map: the DAG as an SVG (illumination-colored nodes, parent rails +
// fan-in edges). Toggled with `m`; click a node to jump there. ───────────────
const NW = 158, NH = 28, COL = 178, ROWH = 56, PADX = 80, PADY = 44;
function ForestMap(props) {
  // tree-row layout: a node inherits its parent's row when it's the first child, so a
  // linear chain runs HORIZONTALLY (x = depth); branches/extra roots drop to a new row.
  const pos = createMemo(() => {
    const list = props.spine();
    const byId = {};
    list.forEach((n) => (byId[n.id] = n));
    const row = {};
    let next = 0;
    const walk = (id, inherit) => {
      if (id in row) return;
      row[id] = inherit != null ? inherit : next++;
      const kids = (byId[id]?.children || []).filter((k) => byId[k]);
      kids.forEach((k, i) => walk(k, i === 0 ? row[id] : next++));
    };
    list.filter((n) => n.depth === 0).forEach((rt) => walk(rt.id, null));
    list.forEach((n) => { if (!(n.id in row)) row[n.id] = next++; });
    const m = {};
    list.forEach((n) => {
      m[n.id] = { x: PADX + n.depth * COL, y: PADY + row[n.id] * ROWH, n };
    });
    return m;
  });
  const W = () =>
    Math.max(0, ...Object.values(pos()).map((p) => p.x)) + NW + PADX;
  const H = () => props.spine().length * ROWH + PADY;
  const edges = createMemo(() => {
    const P = pos(), out = [];
    for (const n of props.spine()) {
      const c = P[n.id];
      if (!c) continue;
      const par = P[n.parent];
      if (par) out.push({ ...curve(par, c), kind: "rail" });
      for (const req of n.requires || []) {
        const r = P[req];
        if (r) out.push({ ...curve(r, c), kind: "fanin" });
      }
    }
    return out;
  });
  function curve(a, b) {
    const x1 = a.x + NW, y1 = a.y + NH / 2, x2 = b.x, y2 = b.y + NH / 2, mx = (x1 + x2) / 2;
    return { d: `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}` };
  }
  return (
    <div class="map-overlay" onClick={() => props.onClose()}>
      <svg class="map-svg" width={W()} height={H()} onClick={(e) => e.stopPropagation()}>
        <For each={edges()}>{(e) => <path class={`ge ${e.kind}`} d={e.d} />}</For>
        <For each={props.spine()}>
          {(n) => {
            const c = () => pos()[n.id];
            return (
              <g
                class={`gnode ${lumen(n)}`}
                classList={{ active: n.id === props.active() }}
                transform={`translate(${c().x},${c().y})`}
                onClick={() => props.onPick(n.id)}
              >
                <rect width={NW} height={NH} rx="8" />
                <circle class="gdot" cx="14" cy={NH / 2} r="4" />
                <text x="28" y={NH / 2 + 4}>{leaf(n.id)}</text>
                <text class="gcount" x={NW - 11} y={NH / 2 + 4} text-anchor="end">
                  {n.clean}/{n.total}
                </text>
              </g>
            );
          }}
        </For>
      </svg>
    </div>
  );
}

// ── node detail: forest spine + review surface ───────────────────────
function NodeDetail(props) {
  const qc = useQueryClient();
  const project = () => props.url().project;

  const model = createQuery(() => ({
    queryKey: ["model", project()],
    queryFn: () => fetchJSON("/model?branch=" + encodeURIComponent(project())),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  const active = () => props.url().node || spine()[0]?.id || project();
  const parentOf = () => model.data?.nodes?.[active()]?.parent;

  // diff base: parent ("") | main | last-blessed ("blessed"); resets when you change node.
  const [base, setBase] = createSignal("");
  let lastActive;
  createEffect(() => {
    if (active() !== lastActive) {
      lastActive = active();
      setBase("");
    }
  });

  const node = createQuery(() => ({
    queryKey: ["node", active(), base()],
    queryFn: () =>
      fetchJSON(
        "/node?branch=" + encodeURIComponent(active()) + (base() ? "&base=" + base() : "")
      ),
    enabled: !!active(),
  }));

  const bless = createMutation(() => ({
    mutationFn: (file) =>
      fetch("/bless", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file }),
      }).then((r) => r.json()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["node", active()] });
      qc.invalidateQueries({ queryKey: ["model"] });
    },
  }));

  const goto = (b) => (location.hash = "node=" + b);
  const litCount = () => spine().filter((n) => lumen(n) === "blessed").length;
  const BASES = [["", "parent"], ["main", "main"], ["blessed", "last blessed"]];
  const [showMap, setShowMap] = createSignal(false);

  // keyboard: j/k walk the spine; 1/2/3 switch the diff base; m toggles the forest map.
  const onKey = (e) => {
    if (e.target.matches("input, textarea, [contenteditable]")) return;
    const list = spine();
    const i = list.findIndex((n) => n.id === active());
    if (e.key === "j" && i < list.length - 1) { e.preventDefault(); goto(list[i + 1].id); }
    else if (e.key === "k" && i > 0) { e.preventDefault(); goto(list[i - 1].id); }
    else if (e.key === "1") setBase("");
    else if (e.key === "2") setBase("main");
    else if (e.key === "3") setBase("blessed");
    else if (e.key === "m") setShowMap((v) => !v);
    else if (e.key === "Escape") setShowMap(false);
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));

  // on node change: jump to top, keep the active spine entry in view.
  createEffect(() => {
    active();
    window.scrollTo({ top: 0 });
    queueMicrotask(() =>
      document.querySelector(".spine-node.active")?.scrollIntoView({ block: "nearest" })
    );
  });

  return (
    <div class="shell">
      <aside class="spine">
        <a class="brand" href="?">
          <span class="brand-mark">✦</span> blessed
        </a>
        <Show when={spine().length} fallback={<div class="spine-empty">{project()}</div>}>
          <div class="spine-meta">{litCount()}/{spine().length} lit</div>
          <ul class="spine-list">
            <For each={spine()}>
              {(n) => (
                <li
                  class="spine-node"
                  classList={{ active: n.id === active() }}
                  style={{ "padding-left": `${10 + n.depth * 14}px` }}
                  onClick={() => goto(n.id)}
                  title={n.id}
                >
                  <span class={`dot ${lumen(n)}`} />
                  <span class="spine-name">{leaf(n.id)}</span>
                  <span class="spine-count">{n.clean}<span class="slash">/</span>{n.total}</span>
                </li>
              )}
            </For>
          </ul>
        </Show>
      </aside>

      <main class="surface">
        <header class="node-head">
          <h1>{leaf(active()) || "—"}</h1>
          <Show when={parentOf()}>
            <span class="against">◂ {leaf(parentOf())}</span>
          </Show>
          <span class="meta">
            {node.isFetching
              ? "syncing…"
              : node.isError
                ? "couldn't load — retrying"
                : node.data
                  ? `${node.data.files.filter(isBlessed).length}/${node.data.files.length} blessed`
                  : ""}
          </span>
          <button class="map-btn" onClick={() => setShowMap(true)} title="forest map (m)">
            ⊞ map
          </button>
        </header>
        <div class="base-toggle">
          <span class="base-label">diff vs</span>
          <For each={BASES}>
            {([v, lab]) => (
              <button
                class="base-pill"
                classList={{ on: base() === v }}
                onClick={() => setBase(v)}
              >
                {lab}
              </button>
            )}
          </For>
        </div>
        <Show when={node.data} fallback={<p class="loading">loading…</p>}>
          <Show when={node.data.files.length} fallback={<p class="loading">nothing to review here ✦</p>}>
            <For each={node.data.files}>{(f) => <FileEntry file={f} bless={bless} />}</For>
          </Show>
        </Show>
      </main>
      <Show when={showMap()}>
        <ForestMap
          spine={spine}
          active={active}
          onPick={(b) => {
            goto(b);
            setShowMap(false);
          }}
          onClose={() => setShowMap(false)}
        />
      </Show>
    </div>
  );
}

function FileEntry(props) {
  const [foil, setFoil] = createSignal(false);
  const blessed = () => isBlessed(props.file);
  const doBless = () => {
    setFoil(true); // play the foil on the click — feels instant; the steady gold lands on refetch
    props.bless.mutate(props.file.path);
    setTimeout(() => setFoil(false), 750);
  };
  const html = () =>
    props.file.patch
      ? Diff2Html.html(props.file.patch, {
          drawFileList: false,
          outputFormat: "side-by-side",
          matching: "lines",
          colorScheme: "dark",
        })
      : `<p class="empty">no textual diff</p>`;
  const seg = (p) => {
    const i = p.lastIndexOf("/");
    return i < 0 ? <b>{p}</b> : [<span class="dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };
  return (
    <article class="entry" classList={{ blessed: blessed(), foil: foil() }}>
      <div class="entry-head">
        <span class="gutter">{blessed() || foil() ? "✦" : ""}</span>
        <span class="path">{seg(props.file.path)}</span>
        <span class="lines">
          <span class="add">+{props.file.add ?? 0}</span>
          <span class="del">−{props.file.del ?? 0}</span>
        </span>
        <button class="bless-btn" disabled={blessed()} onClick={doBless}>
          {blessed() ? "blessed" : "bless ✦"}
        </button>
      </div>
      <div class="diff" innerHTML={html()} />
    </article>
  );
}
