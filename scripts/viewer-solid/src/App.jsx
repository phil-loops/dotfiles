import { createSignal, createMemo, Show, For, onCleanup } from "solid-js";
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
        <h2 class="eyebrow">forests</h2>
        <Show when={(projects.data || []).length} fallback={<p class="loading">no forests configured</p>}>
          <For each={projects.data}>
            {(p) => (
              <a class="forest-row" href={`?branch=${encodeURIComponent(p.name)}`}>
                <span class={`forest-dot ${p.behind > 0 ? "behind" : "fresh"}`} />
                <span class="forest-name">{p.name}</span>
                <span class="forest-meta">{p.branches} {p.branches === 1 ? "node" : "nodes"}</span>
                <span class={`forest-fresh ${p.behind > 0 ? "behind" : "fresh"}`}>
                  {p.behind > 0 ? `⟳ ${p.behind} behind` : "✦ fresh"}
                </span>
              </a>
            )}
          </For>
        </Show>
      </section>
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

  const node = createQuery(() => ({
    queryKey: ["node", active()],
    queryFn: () => fetchJSON("/node?branch=" + encodeURIComponent(active())),
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
        </header>
        <Show when={node.data} fallback={<p class="loading">loading…</p>}>
          <Show when={node.data.files.length} fallback={<p class="loading">nothing to review here ✦</p>}>
            <For each={node.data.files}>{(f) => <FileEntry file={f} bless={bless} />}</For>
          </Show>
        </Show>
      </main>
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
