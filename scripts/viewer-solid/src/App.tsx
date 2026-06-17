import {
  createSignal,
  createMemo,
  createEffect,
  Show,
  For,
  onCleanup,
  type JSX,
} from "solid-js";
import {
  createQuery,
  createMutation,
  useQueryClient,
} from "@tanstack/solid-query";
import * as Diff2Html from "diff2html";
import { ColorSchemeType } from "diff2html/lib/types";
import { fetchJSON } from "./api";
import { NodeActions } from "./NodeActions";
import type {
  ForestModel,
  SpineNode,
  NodeMeta,
  FileDiff,
  NodeData,
  PR,
  Project,
  Standalone,
  Purpose,
  Commit,
  RestackStatus,
  Parked,
} from "./types";

// ── url ──────────────────────────────────────────────────────────────
// ?branch=<project> chooses a forest; #node=<branch> the node you're reading.
// No project → the home (your ledger summary). Project, no node → its tip.
function readUrl() {
  const q = new URLSearchParams(location.search);
  const h = new URLSearchParams(location.hash.replace(/^#/, ""));
  return { project: q.get("branch") || "", node: h.get("node") || "" };
}
const leaf = (s?: string): string => (s || "").split("/").pop() ?? "";
const isBlessed = (f: FileDiff): boolean =>
  f.status === "clean" || f.status === "blessed";

function flattenForest(model: ForestModel | undefined): SpineNode[] {
  if (!model) return [];
  const nodes = model.nodes;
  if (nodes) {
    const out: SpineNode[] = [];
    const seen = new Set<string>();
    const walk = (b: string, d: number) => {
      if (seen.has(b)) return;
      seen.add(b);
      const n = nodes[b];
      if (!n) return;
      out.push({ ...n, id: b, depth: d });
      (n.children || []).forEach((c) => walk(c, d + 1));
    };
    (model.roots || []).forEach((r) => walk(r, 0));
    Object.keys(nodes).forEach((b) => !seen.has(b) && walk(b, 0));
    return out;
  }
  return (model.links || []).map(
    (l) => ({ ...l, id: l.branch, depth: 0 }) as unknown as SpineNode
  );
}
function lumen(n: NodeMeta): "stale" | "blessed" | "unblessed" {
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
    queryFn: () => fetchJSON<PR[]>("/myprs"),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => fetchJSON<Project[]>("/projects"),
  }));
  const checkOrigin = createMutation(() => ({
    mutationFn: () => fetch("/check-origin", { method: "POST", body: "{}" }).then((r) => r.json()),
    onSuccess: () => {
      prs.refetch();
      projects.refetch();
    },
  }));

  // ── restack: two-click arm → run (background) → poll → parked? hand to Claude ──
  const [armed, setArmed] = createSignal<string | null>(null); // project (or "__all__") awaiting confirm
  const [running, setRunning] = createSignal<string | null>(null); // project (or "__all__") restacking now
  const [parked, setParked] = createSignal<Parked | null>(null); // set on a conflict
  let armT: ReturnType<typeof setTimeout>;
  const post = (url: string, body: unknown): Promise<{ ok?: boolean }> =>
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  const start = (key: string) => {
    setParked(null);
    const body =
      key === "__all__"
        ? { projects: (projects.data || []).filter((p) => p.behind > 0).map((p) => p.name) }
        : { project: key };
    post(key === "__all__" ? "/restack-all" : "/restack", body).then((r) => {
      if (r.ok) setRunning(key);
    });
  };
  const arm = (key: string) => {
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
      fetchJSON<RestackStatus>(
        "/restack-status" +
          (running() && running() !== "__all__"
            ? "?project=" + encodeURIComponent(running()!)
            : "")
      ),
    enabled: !!running(),
    refetchInterval: (q) => (q.state.data?.running === false ? false : 2500),
  }));
  createEffect(() => {
    if (!running()) return;
    const d = status.data;
    if (!d || d.running) return; // still churning through the topo walk
    if (d.paused)
      setParked({ project: d.project ?? "", current: d.current ?? "", reason: d.reason ?? "" });
    setRunning(null);
    projects.refetch();
  });
  const resolve = (project: string) =>
    post("/restack-resolve", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setRunning(project); // re-poll while Claude resolves + resumes
      }
    });

  // ── watching: opt-in pinned loose branches (git config stack.standalone) ──
  // Not auto-discovery — branches you deliberately pin to keep an eye on. /branches
  // (the typeahead source, ~all local heads) is heavy, so only fetch it while adding.
  const standalone = createQuery(() => ({
    queryKey: ["standalone"],
    queryFn: () => fetchJSON<Standalone[]>("/standalone"),
  }));
  const [adding, setAdding] = createSignal(false);
  const [pick, setPick] = createSignal("");
  const branches = createQuery(() => ({
    queryKey: ["branches"],
    queryFn: () => fetchJSON<string[]>("/branches"),
    enabled: adding(),
  }));
  const pin = createMutation(() => ({
    mutationFn: (body: { branch: string; op?: string }) => post("/standalone", body),
    onSuccess: () => { standalone.refetch(); branches.refetch(); },
  }));
  const submitPin = () => {
    const b = pick().trim();
    if (!b) return;
    pin.mutate({ branch: b });
    setPick("");
    setAdding(false);
  };

  const byProject = createMemo<[string, PR[]][]>(() => {
    const m = new Map<string, PR[]>();
    for (const p of prs.data || []) {
      const k = p.project || "—";
      if (!m.has(k)) m.set(k, []);
      m.get(k)!.push(p);
    }
    return [...m.entries()];
  });

  const review = (r?: string | null): [string, string] =>
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

      <section>
        <div class="eyebrow-row">
          <h2 class="eyebrow">watching</h2>
          <button class="watch-add" onClick={() => setAdding((v) => !v)}>
            {adding() ? "× cancel" : "+ watch a branch"}
          </button>
        </div>
        <Show when={adding()}>
          <div class="watch-pick">
            <input
              class="watch-input"
              list="watch-branches"
              placeholder="branch name…"
              value={pick()}
              onInput={(e) => setPick(e.currentTarget.value)}
              onKeyDown={(e) => e.key === "Enter" && submitPin()}
              autofocus
            />
            <datalist id="watch-branches">
              <For each={branches.data || []}>{(b) => <option value={b} />}</For>
            </datalist>
            <button class="watch-pin" disabled={!pick().trim()} onClick={submitPin}>
              pin
            </button>
          </div>
        </Show>
        <Show
          when={(standalone.data || []).length}
          fallback={<p class="loading">nothing pinned — watch a loose branch to track it here</p>}
        >
          <For each={standalone.data}>
            {(b) => (
              <div class="watch-row">
                <a class="watch-link" href={`?branch=${encodeURIComponent(b.branch)}`}>
                  <span class="watch-dot" />
                  <span class="watch-name">{b.branch}</span>
                  <span class="watch-meta">
                    <span>{b.commits} {b.commits === 1 ? "commit" : "commits"}</span>
                    <span class="watch-add-n">+{b.add}</span>
                    <span class="watch-del-n">−{b.del}</span>
                  </span>
                </a>
                <button
                  class="watch-unpin"
                  title="stop watching"
                  onClick={() => pin.mutate({ branch: b.branch, op: "remove" })}
                >
                  ×
                </button>
              </div>
            )}
          </For>
        </Show>
      </section>
    </div>
  );
}

// ── forest map: the DAG as an SVG (illumination-colored nodes, parent rails +
// fan-in edges). Toggled with `m`; click a node to jump there. ───────────────
const NW = 158, NH = 28, COL = 178, ROWH = 56, PADX = 80, PADY = 44;
function ForestMap(props: {
  spine: () => SpineNode[];
  active: () => string;
  onPick: (b: string) => void;
  onClose: () => void;
}) {
  type Pt = { x: number; y: number; n: SpineNode };
  // tree-row layout: a node inherits its parent's row when it's the first child, so a
  // linear chain runs HORIZONTALLY (x = depth); branches/extra roots drop to a new row.
  const pos = createMemo<Record<string, Pt>>(() => {
    const list = props.spine();
    const byId: Record<string, SpineNode> = {};
    list.forEach((n) => (byId[n.id] = n));
    const row: Record<string, number> = {};
    let next = 0;
    const walk = (id: string, inherit: number | null) => {
      if (id in row) return;
      row[id] = inherit != null ? inherit : next++;
      const kids = (byId[id]?.children || []).filter((k) => byId[k]);
      kids.forEach((k, i) => walk(k, i === 0 ? row[id] : next++));
    };
    list.filter((n) => n.depth === 0).forEach((rt) => walk(rt.id, null));
    list.forEach((n) => { if (!(n.id in row)) row[n.id] = next++; });
    const m: Record<string, Pt> = {};
    list.forEach((n) => {
      m[n.id] = { x: PADX + n.depth * COL, y: PADY + row[n.id] * ROWH, n };
    });
    return m;
  });
  const W = () =>
    Math.max(0, ...Object.values(pos()).map((p) => p.x)) + NW + PADX;
  const H = () => props.spine().length * ROWH + PADY;
  const edges = createMemo<{ d: string; kind: string }[]>(() => {
    const P = pos();
    const out: { d: string; kind: string }[] = [];
    for (const n of props.spine()) {
      const c = P[n.id];
      if (!c) continue;
      if (n.parent) {
        const par = P[n.parent];
        if (par) out.push({ ...curve(par, c), kind: "rail" });
      }
      for (const req of n.requires || []) {
        const r = P[req];
        if (r) out.push({ ...curve(r, c), kind: "fanin" });
      }
    }
    return out;
  });
  function curve(a: { x: number; y: number }, b: { x: number; y: number }) {
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
function NodeDetail(props: { url: () => { project: string; node: string } }) {
  const qc = useQueryClient();
  const project = () => props.url().project;

  const model = createQuery(() => ({
    queryKey: ["model", project()],
    queryFn: () => fetchJSON<ForestModel>("/model?branch=" + encodeURIComponent(project())),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  const active = () => props.url().node || spine()[0]?.id || project();
  const parentOf = () => model.data?.nodes?.[active()]?.parent;

  // diff base + view (diffs|commits) reset when you change node.
  const [base, setBase] = createSignal(""); // "" parent | "main" | "blessed" last-blessed
  const [view, setView] = createSignal<"diffs" | "commits">("diffs");
  let lastActive: string | undefined;
  createEffect(() => {
    if (active() !== lastActive) {
      lastActive = active();
      setBase("");
      setView("diffs");
    }
  });

  const node = createQuery(() => ({
    queryKey: ["node", active(), base()],
    queryFn: () =>
      fetchJSON<NodeData>(
        "/node?branch=" + encodeURIComponent(active()) + (base() ? "&base=" + base() : "")
      ),
    enabled: !!active(),
  }));
  const commits = createQuery(() => ({
    queryKey: ["commits", active()],
    queryFn: () => fetchJSON<Commit[]>("/commits?branch=" + encodeURIComponent(active())),
    enabled: !!active() && view() === "commits",
  }));

  const bless = createMutation(() => ({
    mutationFn: (file: string) =>
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

  const goto = (b: string) => (location.hash = "node=" + b);
  const litCount = () => spine().filter((n) => lumen(n) === "blessed").length;
  const BASES: [string, string][] = [["", "parent"], ["main", "main"], ["blessed", "last blessed"]];
  const [showMap, setShowMap] = createSignal(false);

  // hover a spine node → float its branch purpose (the one-line thesis) beside it.
  // Purposes are cheap + immutable for a session, so cache by branch and guard the
  // async gap (if the pointer left before /purpose resolved, don't pop a stale tip).
  const purposeCache = new Map<string, Purpose>();
  const [tip, setTip] = createSignal<{ text: string; x: number; y: number } | null>(null);
  let tipBranch: string | null = null;
  const showTip = async (branch: string, el: HTMLElement) => {
    tipBranch = branch;
    let p = purposeCache.get(branch);
    if (!p) {
      try { p = await fetchJSON<Purpose>("/purpose?branch=" + encodeURIComponent(branch)); }
      catch { p = { thesis: "" }; }
      purposeCache.set(branch, p);
    }
    if (tipBranch !== branch || !p.thesis) return;
    const r = el.getBoundingClientRect();
    setTip({ text: p.thesis, x: r.right + 12, y: r.top });
  };
  const hideTip = () => { tipBranch = null; setTip(null); };

  // hover a diff line + press o (or click the gutter #) → open that exact line in the warm
  // review-nvim. Event-delegated off the surface so it works on diff2html's raw HTML.
  const [hover, setHover] = createSignal<{ path: string; line: number } | null>(null);
  const [flash, setFlash] = createSignal("");
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => { setFlash(m); clearTimeout(flashT); flashT = setTimeout(() => setFlash(""), 1900); };
  const openInNvim = (path: string, line: number | null) =>
    fetch("/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: active(), path, ...(line != null ? { pos: String(line) } : {}) }),
    })
      .then((r) => r.json())
      .then((r) => note(r.ok ? `⌁ ${leaf(path)}:${line ?? ""} → nvim` : "⌁ open failed — see server"))
      .catch(() => note("⌁ open failed — server unreachable"));
  const lineAt = (e: MouseEvent): { path: string; line: number } | null => {
    const target = e.target as Element | null;
    const ent = target?.closest<HTMLElement>(".entry");
    const ln = target?.closest<HTMLElement>(".d2h-code-side-linenumber, .d2h-code-linenumber");
    if (!ent || !ln) return null;
    const n = parseInt((ln.textContent || "").trim(), 10);
    return n ? { path: ent.dataset.path ?? "", line: n } : null;
  };

  // keyboard: j/k walk the spine; 1/2/3 switch the diff base; m toggles the forest map.
  const onKey = (e: KeyboardEvent) => {
    if ((e.target as Element).matches("input, textarea, [contenteditable]")) return;
    const list = spine();
    const i = list.findIndex((n) => n.id === active());
    if (e.key === "j" && i < list.length - 1) { e.preventDefault(); goto(list[i + 1].id); }
    else if (e.key === "k" && i > 0) { e.preventDefault(); goto(list[i - 1].id); }
    else if (e.key === "1") setBase("");
    else if (e.key === "2") setBase("main");
    else if (e.key === "3") setBase("blessed");
    else if (e.key === "m") setShowMap((v) => !v);
    else if (e.key === "Escape") setShowMap(false);
    else if (e.key === "o" && hover()) { e.preventDefault(); const h = hover()!; openInNvim(h.path, h.line); }
    else if (e.key === "c") setView((v) => (v === "commits" ? "diffs" : "commits"));
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
                  onMouseEnter={(e) => showTip(n.id, e.currentTarget)}
                  onMouseLeave={hideTip}
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

      <main
        class="surface"
        onMouseOver={(e) => {
          const h = lineAt(e);
          if (h) setHover(h);
        }}
        onClick={(e) => {
          const h = lineAt(e);
          if (h) openInNvim(h.path, h.line);
        }}
      >
        <header class="node-head">
          <h1>{leaf(active()) || "—"}</h1>
          <Show when={parentOf()}>
            <span class="against">◂ {leaf(parentOf())}</span>
          </Show>
          <div class="view-toggle">
            <button class="view-pill" classList={{ on: view() === "diffs" }} onClick={() => setView("diffs")}>
              diffs
            </button>
            <button class="view-pill" classList={{ on: view() === "commits" }} onClick={() => setView("commits")}>
              commits
            </button>
          </div>
          <span class="meta">
            {node.isFetching
              ? "syncing…"
              : node.isError
                ? "couldn't load — retrying"
                : node.data
                  ? `${node.data.files.filter(isBlessed).length}/${node.data.files.length} blessed`
                  : ""}
          </span>
          <NodeActions branch={active()} />
          <button class="map-btn" onClick={() => setShowMap(true)} title="forest map (m)">
            ⊞ map
          </button>
        </header>
        <Show when={view() === "diffs"} fallback={<CommitsList q={commits} />}>
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
            <span class="kbd-hint">hover a line · <b>o</b> → nvim</span>
          </div>
          <Show when={node.data} fallback={<p class="loading">loading…</p>}>
            {(data) => (
              <Show when={data().files.length} fallback={<p class="loading">nothing to review here ✦</p>}>
                <For each={data().files}>{(f) => <FileEntry file={f} bless={bless} />}</For>
              </Show>
            )}
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
      <Show when={flash()}>
        <div class="flash">{flash()}</div>
      </Show>
      <Show when={tip()}>
        {(t) => (
          <div class="purpose-tip" style={{ left: `${t().x}px`, top: `${t().y}px` }}>
            {t().text}
          </div>
        )}
      </Show>
    </div>
  );
}

function FileEntry(props: { file: FileDiff; bless: { mutate: (file: string) => void } }) {
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
          colorScheme: ColorSchemeType.DARK,
        })
      : `<p class="empty">no textual diff</p>`;
  const seg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0 ? <b>{p}</b> : [<span class="dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };
  return (
    <article class="entry" data-path={props.file.path} classList={{ blessed: blessed(), foil: foil() }}>
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

function CommitsList(props: { q: { data: Commit[] | undefined } }) {
  return (
    <Show when={props.q.data} fallback={<p class="loading">loading…</p>}>
      {(data) => (
        <Show
          when={data().length}
          fallback={<p class="loading">no commits on this branch</p>}
        >
          <ol class="commits">
            <For each={data()}>
              {(c) => (
                <li class="commit">
                  <span class="c-sha">{c.sha}</span>
                  <span class="c-subject">{c.subject}</span>
                  <span class="c-meta">{c.author} · {c.date}</span>
                </li>
              )}
            </For>
          </ol>
        </Show>
      )}
    </Show>
  );
}
