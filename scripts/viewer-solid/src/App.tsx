import {
  createSignal,
  createMemo,
  createEffect,
  Show,
  Switch,
  Match,
  For,
  onCleanup,
  type JSX,
} from "solid-js";
import {
  createQuery,
  createMutation,
  useQueryClient,
} from "@tanstack/solid-query";
import { RouterProvider, useViewerLocation, Link, forestKey, withNode, type HomeTab, type ViewerLocation } from "./router";
import { ActionBar, type Action } from "./actions";
import * as Diff2Html from "diff2html";
import { ColorSchemeType } from "diff2html/lib/types";
import { provider, canMutate } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { NodeActions } from "./NodeActions";
import { ForestMap } from "./ForestMap";
import MergeStory from "./MergeStory";
import { overviewView, setOverviewView } from "./overviewView";
import { useDiffSelection } from "./useDiffSelection";
import AskClaudeChip from "./AskClaudeChip";
import ChatPanel from "./ChatPanel";
import ChatIndex from "./ChatIndex";
import { chatTarget, openChat, closeChat } from "./chatDrawer";
import { threadMsgCount, threadWorking, threadUnseenDone } from "./chatStore";
import { reconcile as reconcileChats } from "./chatRunner";
import { useFileCycle } from "./useFileCycle";
import CommandPalette from "./CommandPalette";
import { track, installFetchTracking, installUiTracking } from "./track";
import { ServerStatus } from "./ServerStatus";
import { Hearth } from "./Hearth";
import MobilePush from "./MobilePush";
import type {
  ForestModel,
  SpineNode,
  FileDiff,
  NodeData,
  PR,
  Project,
  Purpose,
  Commit,
  RestackStatus,
  Parked,
  ReviewRequest,
} from "./types";

const leaf = (s?: string): string => (s || "").split("/").pop() ?? "";

// Relative age of a merge, or null once it's older than a week (don't badge stale merges).
const mergedAgo = (iso?: string): string | null => {
  const t = iso ? Date.parse(iso) : NaN;
  if (!t) return null;
  const s = Math.max(0, (Date.now() - t) / 1000);
  if (s > 7 * 86400) return null;
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
};
const isBlessed = (f: FileDiff): boolean => f.status === "clean";

// node-view file filter + the `?` shortcut cheatsheet — scoped here so it rides the viewer palette
// without touching the shared index.css.
const NODE_KBD_CSS = `
.file-filter {
  width: 100%; box-sizing: border-box; margin: 0 0 8px; font: inherit; font-size: 12px;
  background: var(--bg, #100e0c); color: var(--ink, #e9e2d4);
  border: 1px solid var(--rule, #3a332b); border-radius: 6px; padding: 5px 8px; outline: none;
}
.file-filter:focus { border-color: var(--gold, #e0ad4e); }
.file-filter::placeholder { color: var(--ink-faint, #6f675a); }
.kbd-help-scrim {
  position: fixed; inset: 0; z-index: 70; display: flex; align-items: center; justify-content: center;
  background: rgba(8,7,6,.55);
}
.kbd-help {
  min-width: 320px; max-width: 92vw; padding: 18px 20px; border-radius: 12px;
  background: var(--raised, #1b1815); border: 1px solid var(--rule, #3a332b);
  box-shadow: 0 24px 64px rgba(0,0,0,.5); font-family: "IBM Plex Mono", ui-monospace, monospace;
  color: var(--ink, #e9e2d4);
}
.kbd-help-head { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-faint, #6f675a); margin-bottom: 14px; }
.kbd-help dl { display: grid; grid-template-columns: auto 1fr; gap: 8px 16px; margin: 0; align-items: baseline; }
.kbd-help dl > div { display: contents; }
.kbd-help dt { display: flex; gap: 4px; justify-self: start; margin: 0; }
.kbd-help dt .k {
  font-size: 11px; line-height: 1.5; padding: 1px 7px; border-radius: 5px;
  background: var(--bg, #100e0c); border: 1px solid var(--rule, #3a332b); color: var(--gold, #e0ad4e);
}
.kbd-help dd { margin: 0; font-size: 12.5px; color: var(--ink-dim, #a89e8c); }
`;

// the node you last left via "back to the forest map", so the overview can emphasize where you
// were. Module-scope so it survives the route change from a node to its forest overview.
const [cameFrom, setCameFrom] = createSignal("");

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
// ── router ───────────────────────────────────────────────────────────
export default function App() {
  return (
    <RouterProvider>
      <Layout>
        <Routes />
      </Layout>
    </RouterProvider>
  );
}

// A forest with no node selected is its own altitude — the map IS the view (overview); a
// forest WITH a node, plus every standalone/review, drops into the per-node review surface.
const isForestOverview = (l: ViewerLocation): boolean => l.kind === "forest" && !l.node;

// home is its own kind; a node-less forest lands on the map; everything else is node review.
function Routes() {
  const { location } = useViewerLocation();
  return (
    <Switch>
      <Match when={location().kind === "home"}>
        <Home />
      </Match>
      <Match when={location().kind === "push"}>
        <MobilePush />
      </Match>
      <Match when={isForestOverview(location())}>
        <ForestOverview />
      </Match>
      <Match when={location().kind !== "home"}>
        <NodeDetail />
      </Match>
    </Switch>
  );
}

// Persistent chrome that survives route changes: the SSE stream, the command
// palette, and the server-status pill. The matched route renders as props.children.
function Layout(props: { children?: JSX.Element }) {
  const qc = useQueryClient();
  installFetchTracking(); // every action POST is tracked at the fetch seam — see track.ts
  installUiTracking(); // + button clicks and keyboard shortcuts (the client-only layer)
  // usage telemetry: one event per route change (what you open, in what order). Dwell +
  // bounce are derived offline from the gap between consecutive nav events.
  const { location: loc } = useViewerLocation();
  createEffect(() => {
    const l = loc();
    track("nav", {
      kind: l.kind,
      project: forestKey(l) || undefined,
      node: "node" in l ? l.node : undefined,
    });
  });
  // /events is a persistent SSE stream and the browser only allows ~6 connections per origin
  // (HTTP/1.1) — so a graveyard of idle tabs each squatting a stream exhausts the pool and new
  // loads hang. Hold the stream ONLY while the tab is visible: a backgrounded tab closes it
  // (frees its slot), and re-opening on show refetches to catch up on anything missed.
  let es: EventSource | null = null;
  const refresh = () => {
    qc.invalidateQueries({ queryKey: ["node"] });
    qc.invalidateQueries({ queryKey: ["model"] });
    qc.invalidateQueries({ queryKey: ["projects"] });
  };
  const openStream = () => {
    if (!canMutate || es) return; // static snapshot: no live event stream
    es = new EventSource("/events");
    es.addEventListener("update", refresh);
  };
  const closeStream = () => {
    es?.close();
    es = null;
  };
  const onVisibility = () => {
    if (document.hidden) {
      closeStream();
    } else {
      openStream();
      refresh(); // we may have missed updates while hidden
    }
  };
  if (!document.hidden) openStream();
  reconcileChats(); // re-attach any chat turn left in flight by a reload, so its badge resolves
  document.addEventListener("visibilitychange", onVisibility);
  onCleanup(() => {
    document.removeEventListener("visibilitychange", onVisibility);
    closeStream();
  });

  return (
    <>
      {props.children}
      <ChatDrawerHost />
      <CommandPalette />
      <ServerStatus />
    </>
  );
}

// The chat drawer lives HERE, above the routed views, so it persists across navigation (and, via
// chatDrawer's localStorage mirror, across reload). `viewingBranch` is the branch on screen right
// now — when it differs from the chat's pinned branch, the drawer offers a one-click way back.
function ChatDrawerHost() {
  const { location, navigate } = useViewerLocation();
  const viewingBranch = () => {
    const l = location();
    return l.kind === "forest" ? (l.node ?? "") : l.kind === "standalone" ? l.branch : "";
  };
  return (
    <Show when={canMutate && chatTarget()}>
      <ChatPanel
        file={chatTarget()?.file ?? null}
        branch={chatTarget()?.branch ?? ""}
        viewingBranch={viewingBranch()}
        onGoToBranch={() => { const t = chatTarget(); if (t) { navigate(t.origin); } }}
        onClose={() => closeChat()}
      />
    </Show>
  );
}

// ── home: the ledger summary ─────────────────────────────────────────
function Home() {
  const qc = useQueryClient();
  const prs = createQuery(() => ({
    queryKey: ["myprs"],
    queryFn: () => provider.myPrs(),
  }));
  const projects = createQuery(() => ({
    queryKey: ["projects"],
    queryFn: () => provider.projects(),
  }));
  const checkOrigin = createMutation(() => ({
    mutationFn: () => fetch("/check-origin", { method: "POST", body: "{}" }).then((r) => r.json()),
    onSuccess: () => {
      prs.refetch();
      projects.refetch();
    },
  }));

  // ── restack: two-click arm (via ActionBar) → run (background) → poll → parked? hand to Claude ──
  const [running, setRunning] = createSignal<string | null>(null); // project (or "__all__") restacking now
  const [parked, setParked] = createSignal<Parked | null>(null); // set on a conflict
  const [restackErr, setRestackErr] = createSignal<string | null>(null);
  const [flash, setFlash] = createSignal<string | null>(null);
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => {
    setFlash(m);
    clearTimeout(flashT);
    flashT = setTimeout(() => setFlash(null), 2400);
  };
  const [menu, setMenu] = createSignal<string | null>(null); // project whose parked-action popover is open
  const post = (url: string, body: unknown): Promise<{ ok?: boolean; err?: string }> =>
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());
  const behindNames = () => (projects.data || []).filter((p) => p.behind > 0).map((p) => p.name);
  const start = (key: string) => {
    setRestackErr(null);
    // restack-all clears any pre-existing park first (server frees the worktree, then the
    // resilient walk restacks the rest); a single-project restack never auto-drops a park.
    const body =
      key === "__all__"
        ? { projects: behindNames(), abortParked: !!parked() }
        : { project: key };
    post(key === "__all__" ? "/restack-all" : "/restack", body).then((r) => {
      if (r.ok) {
        setParked(null);
        setRunning(key);
      } else {
        // Don't swallow it — a stale park 409s here; surface why + refresh so the parked
        // branch's contextual button appears on its row.
        setRestackErr(r.err ?? "couldn’t start restack");
        homeStatus.refetch();
      }
    });
  };
  const abort = (project: string) =>
    post("/restack-abort", { project }).then((r) => {
      if (r.ok) {
        setParked(null);
        setRestackErr(null);
        setMenu(null);
        projects.refetch();
        homeStatus.refetch();
      } else {
        setRestackErr(r.err ?? "couldn’t abort");
      }
    });
  // ── delete mode: forget an old forest grouping (config only; branches kept) ──
  const [dropping, setDropping] = createSignal<string | null>(null);
  const dropProject = (project: string) => {
    setDropping(project);
    post("/drop-project", { project }).then((r) => {
      setDropping(null);
      if (r.ok) {
        projects.refetch();
        prs.refetch();
      } else {
        setRestackErr(r.err ?? "couldn’t drop forest");
      }
    });
  };
  onCleanup(() => setDeleteMode(false)); // leaving home always exits delete mode
  const status = createQuery(() => ({
    queryKey: ["restack-status", running()],
    queryFn: () =>
      provider.restackStatus(
        running() && running() !== "__all__" ? running()! : undefined
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
        setMenu(null);
        setRunning(project); // re-poll while Claude resolves + resumes
      }
    });
  // Surface a parked conflict on the home screen even when nothing is running — without
  // this a stale park silently 409s every restack with no clue which branch is stuck.
  const homeStatus = createQuery(() => ({
    queryKey: ["home-restack-status"],
    queryFn: () => provider.restackStatus(),
    refetchInterval: 5000,
  }));
  createEffect(() => {
    if (running()) return; // the running-restack effect owns `parked` mid-walk
    const d = homeStatus.data;
    if (!d) return;
    setParked(
      d.paused ? { project: d.project ?? "", current: d.current ?? "", reason: d.reason ?? "" } : null
    );
  });

  const reviewReqs = createQuery(() => ({
    queryKey: ["review-requests"],
    queryFn: () => provider.reviewRequests(),
    // keep the queue warm in the background so newly-requested PRs surface on their
    // own; 30s matches the server's gh-search cache TTL, so most polls are free.
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
  }));
  const importReview = createMutation(() => ({
    mutationFn: (number: number) => post("/review-import", { number }),
    // flip the row to imported in-place; without this the button drops back to
    // "import" for the frame between the mutation settling and the refetch landing.
    onSuccess: (_res, number) => {
      qc.setQueryData<ReviewRequest[]>(["review-requests"], (cur) =>
        cur?.map((r) => (r.number === number ? { ...r, imported: true } : r)));
    },
  }));

  const { location, navigate } = useViewerLocation();
  const tab = (): HomeTab => {
    const l = location();
    return l.kind === "home" ? l.tab : "work";
  };
  const [forestQuery, setForestQuery] = createSignal("");

  // hover a forest row → a card of its branches + one-line purposes ("what's in here").
  // cached per project; a short delay keeps it from flickering as the pointer crosses rows.
  type FPurpose = { branch: string; thesis: string };
  const [ftip, setFtip] = createSignal<{ rows: FPurpose[]; x: number; y: number } | null>(null);
  const fpCache = new Map<string, FPurpose[]>();
  let ftipFor: string | null = null;
  let ftipTimer: ReturnType<typeof setTimeout> | undefined;
  const showFtip = (project: string, el: HTMLElement) => {
    clearTimeout(ftipTimer);
    ftipFor = project;
    const r = el.getBoundingClientRect();
    const place = (rows: FPurpose[]) => {
      if (ftipFor !== project || !rows.length) return;
      const estH = 18 + rows.length * 44; // ~name + 2-line clamped thesis per row
      // flip above the row when there isn't room below, so the card stays on-screen
      const y = window.innerHeight - r.bottom >= estH + 12 ? r.bottom + 6 : Math.max(8, r.top - estH - 6);
      setFtip({ rows, x: r.left + 18, y });
    };
    const cached = fpCache.get(project);
    if (cached) {
      ftipTimer = setTimeout(() => place(cached), 160);
      return;
    }
    ftipTimer = setTimeout(() => {
      fetch("/forest-purposes?project=" + encodeURIComponent(project))
        .then((res) => res.json() as Promise<FPurpose[]>)
        .then((rows) => { fpCache.set(project, rows); place(rows); })
        .catch(() => {});
    }, 160);
  };
  const hideFtip = () => { clearTimeout(ftipTimer); ftipFor = null; setFtip(null); };

  const byProject = createMemo<[string, PR[]][]>(() => {
    const m = new Map<string, PR[]>();
    for (const p of prs.data || []) {
      const k = p.project || "—";
      if (!m.has(k)) m.set(k, []);
      m.get(k)!.push(p);
    }
    return [...m.entries()];
  });

  const forestOf = (name: string): Project | undefined => (projects.data || []).find((p) => p.name === name);
  // the open PR for a forest, if any — drives the [PR #N] badge so a PR'd forest stays in the
  // Forests list (the complete index) instead of vanishing the moment it gets a PR.
  const prOf = (name: string): PR | undefined => (prs.data || []).find((p) => p.project === name);

  const filteredForests = createMemo(() => {
    const needle = forestQuery().trim().toLowerCase();
    const list = projects.data || [];
    return needle ? list.filter((p) => p.name.toLowerCase().includes(needle)) : list;
  });
  const workCount = () => (prs.data || []).length + (reviewReqs.data || []).length;

  const review = (r?: string | null): [string, string] =>
    r === "APPROVED" ? ["✓", "ok"] : r === "CHANGES_REQUESTED" ? ["▲", "chg"] : ["•", "req"];

  const restacking = (name: string) => () => running() === name || running() === "__all__";
  const restackAction = (p: Project): Action => ({
    id: "restack:" + p.name,
    class: "forest-restack",
    arm: true,
    busy: restacking(p.name),
    label: () => (restacking(p.name)() ? "⤳ restacking…" : `⟳ ${p.behind} behind`),
    armLabel: () => "restack?",
    run: () => start(p.name),
  });
  const dropAction = (p: Project): Action => ({
    id: "drop:" + p.name,
    class: "forest-drop",
    arm: true,
    busy: () => dropping() === p.name,
    label: () => (dropping() === p.name ? "⌫ dropping…" : "✕ drop"),
    armLabel: () => "drop forest?",
    run: () => dropProject(p.name),
  });
  const restackAllAction = (): Action => ({
    id: "restack:__all__",
    class: "restack-all",
    arm: true,
    busy: () => running() === "__all__",
    label: () => (running() === "__all__" ? "⤳ restacking all…" : `⟳ restack all ${behindNames().length} behind`),
    armLabel: () => (parked() ? `drop parked ${leaf(parked()!.project)} & restack all?` : "restack all behind?"),
    run: () => start("__all__"),
  });

  const openWorktree = (branch: string) =>
    post("/worktree", { branch }).then((r) =>
      note(r.ok ? `⌂ revealed ${leaf(branch)} in Finder` : `✗ ${r.err || "couldn’t open worktree"}`));
  const worktreeAction = (branch: string): Action => ({
    id: "wt:" + branch,
    title: "reveal this branch's worktree in Finder — materialises a scratch one if it's checked out nowhere",
    label: () => "⌂ worktree",
    run: () => openWorktree(branch),
  });
  const githubAction = (url: string, branch: string): Action => ({
    id: "gh:" + branch,
    title: "open on GitHub",
    label: () => "↗ GitHub",
    run: () => window.open(url, "_blank"),
  });
  const workRowActions = (p: PR): Action[] =>
    [githubAction(p.url, p.branch), ...(canMutate ? [worktreeAction(p.branch)] : [])];

  return (
    <div class="ledger">
      <nav class="thumb-index">
        <div class="thumb-brand"><span class="brand-mark">✦</span></div>
        <For each={[
          { id: "work" as const, label: "Work", count: workCount() },
          { id: "forests" as const, label: "Forests", count: (projects.data || []).length },
        ]}>
          {(t) => (
            <button
              class="thumb"
              classList={{ active: tab() === t.id }}
              onClick={() => navigate({ kind: "home", tab: t.id })}
            >
              <span class="thumb-label">{t.label}</span>
              <Show when={t.count}>
                <span class="thumb-count">{t.count}</span>
              </Show>
            </button>
          )}
        </For>
      </nav>

      <main class="ledger-page">
        <header class="home-head">
          <div class="brand big">
            <span class="brand-mark">✦</span> blessed
          </div>
          <Show when={canMutate}>
            <button
              class="origin-btn"
              disabled={checkOrigin.isPending}
              onClick={() => checkOrigin.mutate()}
            >
              {checkOrigin.isPending ? "checking…" : "↻ check origin"}
            </button>
          </Show>
        </header>

        <Hearth />

      <Show when={tab() === "work" && (prs.data || []).length}>
        <section>
          <h2 class="eyebrow">your open PRs</h2>
          <For each={byProject()}>
            {([proj, list]) => (
              <div class="pr-group">
                <div class="pr-project">
                  <Show when={forestOf(proj)} fallback={proj}>
                    {(f) => (
                      <>
                        <Link class="pr-project-link" to={{ kind: "forest", name: proj }}>{proj}</Link>
                        <span class="forest-meta">
                          {" · "}{f().branches} {f().branches === 1 ? "node" : "nodes"}{" · "}
                          <span class={f().behind > 0 ? "forest-fresh behind" : "forest-fresh fresh"}>
                            {f().behind > 0 ? `↻ ${f().behind} behind` : "✦ fresh"}
                          </span>
                          <Show when={f().merged && mergedAgo(f().merged!.at)}>
                            {(rel) => (
                              <span class="forest-merged" title={f().merged!.title}>
                                {" · "}✨ merged {rel()} (#{f().merged!.pr})
                              </span>
                            )}
                          </Show>
                        </span>
                      </>
                    )}
                  </Show>
                </div>
                <For each={list}>
                  {(p) => {
                    const [mark, cls] = review(p.review);
                    const inner = () => (
                      <>
                        <span class="pr-num">#{p.num}</span>
                        <span class="pr-title">{p.title}</span>
                        {p.draft && <span class="pr-draft">draft</span>}
                        <span class={`pr-rev ${cls}`}>{mark}</span>
                      </>
                    );
                    // forest-backed PRs route in-app; a bare PR opens GitHub in a new tab.
                    return p.project ? (
                      <div class="watch-row">
                        <Link class="watch-link" to={{ kind: "forest", name: p.project, node: p.branch }}>
                          {inner()}
                        </Link>
                        <ActionBar actions={workRowActions(p)} />
                      </div>
                    ) : (
                      <a class="pr-row" href={p.url} target="_blank">
                        {inner()}
                      </a>
                    );
                  }}
                </For>
              </div>
            )}
          </For>
        </section>
      </Show>

      <Show when={tab() === "forests"}>
      <section>
        <div class="eyebrow-row">
          <h2 class="eyebrow">forests</h2>
          <Show when={deleteMode()}>
            <span class="delete-mode-tag">
              delete mode
              <button class="delete-mode-exit" onClick={() => setDeleteMode(false)}>exit</button>
            </span>
          </Show>
          <Show when={restackErr()}>
            <span class="restack-err">{restackErr()}</span>
          </Show>
          <Show when={canMutate && (projects.data || []).some((p) => p.behind > 0)}>
            <ActionBar actions={[restackAllAction()]} />
          </Show>
        </div>
        <Show when={(projects.data || []).length > 6}>
          <input
            class="forest-search"
            placeholder="filter forests…"
            value={forestQuery()}
            onInput={(e) => setForestQuery(e.currentTarget.value)}
          />
        </Show>
        <Show
          when={filteredForests().length}
          fallback={
            <p class="loading">
              {forestQuery()
                ? `no forest matches “${forestQuery()}”`
                : "no forests configured"}
            </p>
          }
        >
          <For each={filteredForests()}>
            {(p) => {
              const stuck = () => parked()?.project === p.name;
              return (
                <Link
                  class="forest-row"
                  classList={{ parked: stuck() }}
                  to={{ kind: "forest", name: p.name }}
                  onMouseEnter={(e) => showFtip(p.name, e.currentTarget as HTMLElement)}
                  onMouseLeave={hideFtip}
                >
                  <span
                    class={`forest-dot ${stuck() ? "parked" : p.behind > 0 ? "behind" : "fresh"}`}
                  />
                  <span class="forest-name">{p.name}</span>
                  <span class="forest-meta">
                    {p.branches} {p.branches === 1 ? "node" : "nodes"}
                  </span>
                  <Show when={prOf(p.name)}>
                    {(pr) => (
                      <span class="forest-pr" classList={{ draft: pr().draft }} title={pr().title}>
                        {pr().draft ? "draft" : "PR"} #{pr().num}
                      </span>
                    )}
                  </Show>
                  <Show when={p.merged && mergedAgo(p.merged.at)}>
                    {(rel) => (
                      <span class="forest-merged" title={p.merged!.title}>
                        ✨ merged {rel()} (#{p.merged!.pr})
                      </span>
                    )}
                  </Show>
                  <Switch fallback={<span class="forest-fresh fresh">✦ fresh</span>}>
                    <Match when={deleteMode() && canMutate}>
                      <ActionBar actions={[dropAction(p)]} />
                    </Match>
                    <Match when={stuck()}>
                      <div class="forest-parked">
                        <button
                          class="forest-resolve"
                          classList={{ open: menu() === p.name }}
                          onClick={(e) => {
                            e.preventDefault();
                            e.stopPropagation();
                            setMenu(menu() === p.name ? null : p.name);
                          }}
                        >
                          ⚠ parked at {leaf(parked()?.current || p.name)}
                        </button>
                        <Show when={menu() === p.name}>
                          <div
                            class="forest-popover"
                            onClick={(e) => {
                              e.preventDefault();
                              e.stopPropagation();
                            }}
                          >
                            <p class="forest-popover-why">
                              Rebase paused on a conflict
                              {parked()?.current ? ` rebasing ${leaf(parked()!.current)}` : ""}. It holds a
                              worktree and blocks restacks until it’s cleared.
                            </p>
                            <Show when={parked()?.reason}>
                              {(r) => <p class="forest-popover-reason">{r()}</p>}
                            </Show>
                            <div class="forest-popover-actions">
                              <button
                                onClick={(e) => {
                                  e.preventDefault();
                                  e.stopPropagation();
                                  resolve(p.name);
                                }}
                              >
                                ✦ resolve with Claude
                              </button>
                              <button
                                class="danger"
                                onClick={(e) => {
                                  e.preventDefault();
                                  e.stopPropagation();
                                  abort(p.name);
                                }}
                              >
                                ✕ abort & discard
                              </button>
                            </div>
                          </div>
                        </Show>
                      </div>
                    </Match>
                    <Match when={p.behind > 0 && canMutate}>
                      <ActionBar actions={[restackAction(p)]} />
                    </Match>
                    <Match when={p.behind > 0}>
                      <span class="forest-meta">⟳ {p.behind} behind</span>
                    </Match>
                  </Switch>
                </Link>
              );
            }}
          </For>
        </Show>
      </section>
      </Show>

      <Show when={tab() === "work" && !workCount()}>
        <p class="tab-empty">Nothing waiting on you — no open PRs or review requests.</p>
      </Show>

      <Show when={tab() === "work" && (reviewReqs.data || []).length}>
        <section>
          <h2 class="eyebrow">review requests</h2>
          <For each={reviewReqs.data}>
            {(r) => {
              const importing = () => importReview.isPending && importReview.variables === r.number;
              return (
                <div class="watch-row">
                  <Show
                    when={r.imported}
                    fallback={
                      <a class="watch-link" href={r.url} target="_blank">
                        <span class="pr-num">#{r.number}</span>
                        <span class="watch-name">{r.title}</span>
                        <span class="watch-meta"><span>@{r.author}</span></span>
                      </a>
                    }
                  >
                    <Link class="watch-link" to={{ kind: "review", pr: r.number }}>
                      <span class="watch-dot" />
                      <span class="pr-num">#{r.number}</span>
                      <span class="watch-name">{r.title}</span>
                      <span class="watch-meta"><span>@{r.author}</span></span>
                    </Link>
                  </Show>
                  <Show
                    when={canMutate && !r.imported}
                    fallback={<Show when={r.imported}><span class="review-on">on viewer ✓</span></Show>}
                  >
                    <button class="watch-pin review-import" disabled={importing()} onClick={() => importReview.mutate(r.number)}>
                      {importing() ? "importing…" : "import"}
                    </button>
                  </Show>
                </div>
              );
            }}
          </For>
        </section>
      </Show>

        <Show when={flash()}>
          <div class="flash">{flash()}</div>
        </Show>
        <Show when={ftip()}>
          {(t) => (
            <div class="forest-tip" style={{ left: `${t().x}px`, top: `${t().y}px` }}>
              <For each={t().rows}>
                {(r) => (
                  <div class="forest-tip-row">
                    <span class="forest-tip-branch">{leaf(r.branch)}</span>
                    <span class="forest-tip-thesis" classList={{ none: !r.thesis }}>
                      {r.thesis || "no purpose set"}
                    </span>
                  </div>
                )}
              </For>
            </div>
          )}
        </Show>
      </main>
    </div>
  );
}

// ── forest overview: the map as the landing hero (no node selected) ──────
// Picking a node navigates to /forests/<project>/<branch> — the per-node review surface.
const FO_VIEWS_CSS = `
.fo-views { display: inline-flex; gap: 2px; margin-left: auto; }
.fo-views button {
  font: inherit; font-size: 11px; cursor: pointer; padding: 3px 10px; border-radius: 6px;
  color: var(--ink-faint, #6f675a); background: transparent; border: 1px solid transparent;
}
.fo-views button:hover { color: var(--ink-dim, #a89e8c); }
.fo-views button.on { color: var(--gold, #e0ad4e); border-color: var(--rule, #3a332b); background: var(--raised, #1b1815); }
`;

function ForestOverview() {
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const [ovView, setOvView] = [overviewView, setOverviewView]; // shared module signal so ⌘K can open straight into a view
  const model = createQuery(() => ({
    queryKey: ["model", project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  const healthIds = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", healthIds().join(",")],
    queryFn: () =>
      fetch("/forest-health?" + healthIds().map((b) => "branch=" + encodeURIComponent(b)).join("&")).then(
        (r) => r.json() as Promise<Record<string, { drifted: boolean; merged: boolean }>>,
      ),
    enabled: canMutate && healthIds().length > 0,
  }));
  // ghost endstate (✦ <project>) opens its integration diff; every other node opens itself.
  const open = (b: string) => navigate({ kind: "forest", name: project(), node: b });
  const nodeCount = () => spine().filter((n) => !n.id.startsWith("✦")).length;

  // hover a node in the map → float its branch purpose (cached; guard the async gap so a
  // pointer that left before /purpose resolved doesn't pop a stale tip).
  const purposeCache = new Map<string, Purpose>();
  const [tip, setTip] = createSignal<{ text: string; x: number; y: number } | null>(null);
  let tipBranch: string | null = null;
  const showTip = async (branch: string, el: HTMLElement) => {
    tipBranch = branch;
    let p = purposeCache.get(branch);
    if (!p) {
      try { p = await provider.purpose(branch); }
      catch { p = { thesis: "" }; }
      purposeCache.set(branch, p);
    }
    if (tipBranch !== branch || !p.thesis) return;
    const r = el.getBoundingClientRect();
    setTip({ text: p.thesis, x: r.right + 12, y: r.top });
  };
  const hideTip = () => { tipBranch = null; setTip(null); };

  return (
    <div class="forest-overview">
      <header class="fo-head">
        <Link class="brand" to={{ kind: "home", tab: "forests" }}>
          <span class="brand-mark">✦</span> blessed
        </Link>
        <span class="fo-project">{project()}</span>
        <Show when={spine().length}>
          <span class="fo-meta">{nodeCount()} {nodeCount() === 1 ? "node" : "nodes"}</span>
          <div class="fo-views" role="group" aria-label="overview view">
            <button classList={{ on: ovView() === "map" }} onClick={() => setOvView("map")} title="spatial forest map">⊞ map</button>
            <button classList={{ on: ovView() === "story" }} onClick={() => setOvView("story")} title="the feature as ordered semantic commits">≣ story</button>
          </div>
        </Show>
        <style>{FO_VIEWS_CSS}</style>
      </header>
      <Show
        when={spine().length}
        fallback={<p class="loading fo-empty">{model.isLoading ? "loading…" : "no branches in this forest"}</p>}
      >
        <Show
          when={ovView() === "story"}
          fallback={
            <ForestMap
              page
              spine={spine}
              active={() => (spine().some((n) => n.id === cameFrom()) ? cameFrom() : "")}
              health={() => health.data}
              onPick={open}
              onClose={() => {}}
              onHoverNode={showTip}
              onLeaveNode={hideTip}
            />
          }
        >
          <MergeStory model={model.data} project={project()} onPick={open} />
        </Show>
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

// ── node detail: forest spine + review surface ───────────────────────
function NodeDetail() {
  const qc = useQueryClient();
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const nodeParam = (): string | undefined => {
    const l = location();
    return l.kind === "home" || l.kind === "push" ? undefined : l.node;
  };

  const model = createQuery(() => ({
    queryKey: ["model", project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  // default to the first node with actual files — a fan-in forest's first root is often an empty
  // integrator (total 0), so landing there shows a blank surface; skip to one with something to review.
  const active = () =>
    nodeParam() || spine().find((n) => (n.total ?? 0) > 0)?.id || spine()[0]?.id || project();
  const parentOf = () => model.data?.nodes?.[active()]?.parent;
  // remember the node you're on, so popping back to the forest map highlights where you were.
  createEffect(() => active() && setCameFrom(active()));

  // diff base + view (diffs|commits) reset when you change node.
  const [base, setBase] = createSignal(""); // "" parent | "main" | "blessed" last-blessed
  const [view, setView] = createSignal<"diffs" | "commits">("diffs");
  let lastActive: string | undefined;
  createEffect(() => {
    if (active() !== lastActive) {
      lastActive = active();
      setBase("");
      setView("diffs");
      setActiveFile("");
      fileCycle.setCurrent("");
    }
  });

  // the ghost ✦<project> culmination node (picked from the forest map as "~integration"): diff
  // main..refs/stack/<project>-integration — the union of all the project's leaf changes.
  const GHOST = "~integration";
  const isGhost = () => active() === GHOST;
  const nodeRef = () => (isGhost() ? `refs/stack/${project()}-integration` : active());
  const nodeBase = () => (isGhost() ? "main" : base() || undefined);

  const node = createQuery(() => ({
    queryKey: ["node", nodeRef(), nodeBase() ?? ""],
    queryFn: () => provider.node(nodeRef(), nodeBase()),
    enabled: !!active(),
  }));
  const commits = createQuery(() => ({
    queryKey: ["commits", active()],
    queryFn: () => provider.commits(active()),
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

  const unbless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch("/bless", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file, unbless: true }),
      }).then((r) => r.json()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["node", active()] });
      qc.invalidateQueries({ queryKey: ["model"] });
    },
  }));

  // neutralize a footgun tracking ref (renamed/foreign remote or origin/main) by unsetting
  // it — config-only, keeps every commit; GitHub Desktop then offers Publish, not a Pull.
  const detachUpstream = createMutation(() => ({
    mutationFn: (branch: string) =>
      fetch("/fix-upstream", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch }),
      }).then((r) => r.json()),
    onSuccess: () => health.refetch(),
  }));

  // diverged-from-PR-head (local rebased, pushed head stale) → eject a standalone Claude in the
  // branch's worktree to work out the source of truth and reconcile — no force-push, no blind pull.
  const reconcile = createMutation(() => ({
    mutationFn: (branch: string) =>
      fetch("/reconcile", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch }),
      }).then((r) => r.json()),
  }));

  const goto = (b: string) => navigate(withNode(location(), b));
  const BASES: [string, string][] = [["", "parent"], ["main", "main"], ["blessed", "last blessed"]];
  // The forest map is a destination (the /forests/<project> overview), never docked into
  // the review surface — the diff gets the full width. "back to the forest map" lives in the
  // node header (nh-forest-back).

  // ── forest health: per-node drifted (off-parent → its diff balloons to ≈main) / merged-ghost,
  // for badges + a one-click "fix forest" (restack). Live-only; refetch after a fix lands.
  const healthIds = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", healthIds().join(",")],
    queryFn: () =>
      fetch("/forest-health?" + healthIds().map((b) => "branch=" + encodeURIComponent(b)).join("&")).then(
        (r) =>
          r.json() as Promise<
            Record<
              string,
              {
                drifted: boolean;
                merged: boolean;
                parent?: string;
                upstream?: string;
                upstreamBad?: boolean;
                upstreamReason?: string;
                diverged?: boolean;
                ahead?: number;
                behind?: number;
              }
            >
          >,
      ),
    enabled: canMutate && healthIds().length > 0,
  }));
  const nodeHealth = (b: string) => health.data?.[b];
  const unhealthy = createMemo(() =>
    spine().filter((n) => {
      const h = nodeHealth(n.id);
      return h?.drifted || h?.merged;
    }),
  );

  const [fixing, setFixing] = createSignal(false);
  // outcome of the last restack — a 6-branch history rewrite must never read as a no-op.
  // errors/parks stay until the next click; a clean success auto-clears.
  const [fixResult, setFixResult] = createSignal<{ msg: string; ok: boolean } | null>(null);
  // live walk progress while the restack runs (the status file is wiped on a clean
  // finish, so we also latch the last seen total for the success line).
  const [fixProgress, setFixProgress] = createSignal<{ done: number; total: number; current: string } | null>(null);
  let fixSawRunning = false;
  let fixLastTotal = 0;
  let fixStartedAt = 0;
  const fixForest = () => {
    if (fixing()) return;
    setFixResult(null);
    setFixProgress(null);
    fixSawRunning = false;
    fixLastTotal = 0;
    fixStartedAt = Date.now();
    setFixing(true);
    fetch("/restack", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ project: project() }),
    })
      .then((r) => r.json())
      .then((r) => {
        if (!r.ok) {
          setFixing(false);
          setFixResult({ msg: r.err || "restack failed to start", ok: false });
        }
      })
      .catch(() => {
        setFixing(false);
        setFixResult({ msg: "restack failed to start", ok: false });
      });
  };
  const fixStatus = createQuery(() => ({
    queryKey: ["fix-status", project()],
    queryFn: () => provider.restackStatus(project()),
    enabled: fixing(),
    refetchInterval: () => (fixing() ? 1200 : false),
  }));
  createEffect(() => {
    if (!fixing()) return;
    const d = fixStatus.data;
    if (!d) return;
    if (d.running) {
      fixSawRunning = true;
      if (d.total) fixLastTotal = d.total;
      setFixProgress({ done: d.done ?? 0, total: d.total ?? 0, current: d.current ?? "" });
      return;
    }
    // the first poll can land before the background walk spawns — don't call it done
    // until we've actually seen it running (or it parked, or a grace window passed).
    if (!fixSawRunning && !d.paused && Date.now() - fixStartedAt < 2500) return;
    // restack finished (or parked — the Hearth/home owns conflict resolution); refresh in place.
    setFixing(false);
    setFixProgress(null);
    if (d.paused) {
      setFixResult({
        msg: `parked on ${d.current || "a conflict"}${d.reason ? `: ${d.reason}` : ""} — resolve in Hearth`,
        ok: false,
      });
    } else {
      const n = fixLastTotal || d.completed?.length || 0;
      setFixResult({
        msg: n ? `✓ restacked ${n} branch${n === 1 ? "" : "es"}` : "✓ forest restacked",
        ok: true,
      });
      setTimeout(() => setFixResult((r) => (r?.ok ? null : r)), 6000);
    }
    model.refetch();
    health.refetch();
    node.refetch();
  });
  // cross-forest chat index overlay (read-only; every thread in this browser).
  const [showChats, setShowChats] = createSignal(false);
  // a chat the index asked to open on a (possibly other) branch: navigate there, then open the
  // drawer once that node's files have loaded (see the effect below). Cleared once opened.
  const [pendingChat, setPendingChat] = createSignal<{ branch: string; path: string } | null>(null);

  // resolve a chat target into the drawer: prefer the real FileDiff (carries the patch); else
  // synthesize a minimal one so the server computes the diff for that path. "" path → whole branch.
  const openChatFor = (path: string) => {
    const at = { branch: active(), origin: location() };
    if (!path) {
      openChat({ ...at, file: null });
      return;
    }
    const real = node.data?.files.find((f) => f.path === path);
    openChat({ ...at, file: real ?? { path, status: "modified" } });
  };
  // from the index: open a chat in its own branch+file context. Same branch → open now; another
  // branch → navigate (as a standalone node) and let the effect open it once its files arrive.
  const openChatInContext = (branch: string, path: string) => {
    setShowChats(false);
    if (branch === active()) {
      openChatFor(path);
    } else {
      setPendingChat({ branch, path });
      navigate({ kind: "standalone", branch });
    }
  };
  createEffect(() => {
    const p = pendingChat();
    if (p && active() === p.branch && node.data?.files) {
      openChatFor(p.path);
      setPendingChat(null);
    }
  });

  // the sidebar is a GitHub-PR-style file list for the active node; clicking a row
  // scrolls its diff card into view and lights the row. activeFile tracks the lit row.
  const [activeFile, setActiveFile] = createSignal("");
  // Tab / Shift+Tab cycle through this node's diff cards (nvim <leader>gm style); onCurrent
  // lights the matching sidebar row so the list tracks the keyboard cursor.
  const fileCycle = useFileCycle({ onCurrent: setActiveFile });
  const scrollToFile = (path: string) => {
    setActiveFile(path);
    fileCycle.setCurrent(path); // so a following Tab continues from the file you clicked
    document
      .querySelector(`.entry[data-path="${CSS.escape(path)}"]`)
      ?.scrollIntoView({ behavior: "instant", block: "start" });
  };
  // keep the lit sidebar row on screen when Tab cycles to a file scrolled out of the list
  // (block:nearest is a no-op when it's already visible, e.g. right after a click).
  createEffect(() => {
    if (!activeFile()) return;
    queueMicrotask(() =>
      document.querySelector(".file-item.active")?.scrollIntoView({ block: "nearest" })
    );
  });
  // scroll-spy: as you just scroll the diff surface, light the row for the card you're reading —
  // the last card whose top has passed under the toolbar line. rAF-throttled; also seeds the Tab
  // cursor so cycling continues from where you scrolled. (Tab/click route through here too via
  // their own scroll, so all three motions converge on the same lit row.)
  const SPY_OFFSET = 100;
  let spyRaf = 0;
  const onScroll = () => {
    if (spyRaf) return;
    spyRaf = requestAnimationFrame(() => {
      spyRaf = 0;
      const cards = document.querySelectorAll<HTMLElement>(".entry[data-path]");
      if (!cards.length) return;
      let pick = cards[0];
      for (const el of cards) {
        if (el.getBoundingClientRect().top <= SPY_OFFSET) pick = el;
        else break;
      }
      const path = pick.getAttribute("data-path") || "";
      if (path && path !== activeFile()) {
        setActiveFile(path);
        fileCycle.setCurrent(path);
      }
    });
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onCleanup(() => {
    window.removeEventListener("scroll", onScroll);
    if (spyRaf) cancelAnimationFrame(spyRaf);
  });
  // dir/base split so the sidebar greys the folder and bolds the filename (like GitHub).
  const fileSeg = (p: string): JSX.Element => {
    const i = p.lastIndexOf("/");
    return i < 0
      ? (<b>{p}</b>)
      : [<span class="file-dir">{p.slice(0, i + 1)}</span>, <b>{p.slice(i + 1)}</b>];
  };

  // sweep-select diff text → floating "ask Claude" chip → POST /claude. Attributes selected
  // rows to a file via each .entry's existing data-path (see useDiffSelection).
  const { selection: claudeSel, clear: clearClaudeSel } = useDiffSelection();

  // hover a diff line + press o (or click the gutter #) → open that exact line in the warm
  // review-nvim. Event-delegated off the surface so it works on diff2html's raw HTML.
  const [hover, setHover] = createSignal<{ path: string; line: number } | null>(null);
  const [flash, setFlash] = createSignal("");
  let flashT: ReturnType<typeof setTimeout>;
  const note = (m: string) => { setFlash(m); clearTimeout(flashT); flashT = setTimeout(() => setFlash(""), 1900); };
  const openInNvim = (path: string, line: number | null) =>
    !canMutate
      ? undefined // static snapshot: no live nvim to open into
      : fetch("/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch: nodeRef(), path, ...(line != null ? { pos: String(line) } : {}) }),
    })
      .then((r) => r.json())
      .then((r) => note(r.ok ? `⌁ ${leaf(path)}:${line ?? ""} → nvim` : "⌁ open failed — see server"))
      .catch(() => note("⌁ open failed — server unreachable"));
  const lineAt = (e: MouseEvent): { path: string; line: number } | null => {
    const target = e.target as Element | null;
    const ent = target?.closest<HTMLElement>(".entry");
    const tr = target?.closest<HTMLElement>("tr");
    if (!ent || !tr) return null;
    // arm anywhere in the row (code OR gutter) by reading that row's line-number cell —
    // not only when the cursor is over the tiny number itself
    const ln = tr.querySelector<HTMLElement>(".d2h-code-side-linenumber, .d2h-code-linenumber");
    const n = parseInt((ln?.textContent || "").trim(), 10);
    return Number.isFinite(n) ? { path: ent.dataset.path ?? "", line: n } : null;
  };

  // keyboard: j/k walk the spine; 1/2/3 switch the diff base; b toggles the file panel; ? for all.
  const onKey = (e: KeyboardEvent) => {
    // already typing (incl. the filter box) → let everything bubble: a 2nd ⌘F reaches native find
    if ((e.target as Element).matches("input, textarea, [contenteditable]")) return;
    if ((e.metaKey || e.ctrlKey) && e.key === "f") { e.preventDefault(); focusFilter(); return; }
    if (e.metaKey || e.ctrlKey || e.altKey) return; // leave OS/browser chords alone
    const list = spine();
    const i = list.findIndex((n) => n.id === active());
    if (e.key === "j" && i < list.length - 1) { e.preventDefault(); goto(list[i + 1].id); }
    else if (e.key === "k" && i > 0) { e.preventDefault(); goto(list[i - 1].id); }
    else if (e.key === "1") setBase("");
    else if (e.key === "2") setBase("main");
    else if (e.key === "3") setBase("blessed");
    else if (e.key === "o" && hover()) { e.preventDefault(); const h = hover()!; openInNvim(h.path, h.line); }
    else if (e.key === "c") setView((v) => (v === "commits" ? "diffs" : "commits"));
    else if (e.key === "b") { e.preventDefault(); filterAutoOpenedPanel = false; setPanelOpen((v) => !v); } // show / hide the file panel
    // ⇧B blesses the focused file and advances (B·B·B down a branch, no mouse); ⇧U unblesses it in
    // place. Per-file only — there is deliberately no bless-all key.
    else if (e.key === "B" && activeFile()) { e.preventDefault(); bless.mutate(activeFile()); fileCycle.next(); }
    else if (e.key === "U" && activeFile()) { e.preventDefault(); unbless.mutate(activeFile()); }
    else if (e.key === "?") { e.preventDefault(); setShowHelp((v) => !v); }
    else if (e.key === "Escape") {
      // up a level: help → close it; else (when the chat drawer isn't grabbing Esc) → the forest map
      if (showHelp()) { setShowHelp(false); }
      else if (!chatTarget()) { const p = project(); if (p) { navigate({ kind: "forest", name: p }); } }
    }
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

  const [panelOpen, setPanelOpen] = createSignal(true);
  const [fileFilter, setFileFilter] = createSignal("");
  const [showHelp, setShowHelp] = createSignal(false);
  let filterEl: HTMLInputElement | undefined;
  // file filter (⌘F): narrow both the sidebar list and the rendered diffs to matching paths.
  const matchFilter = (f: FileDiff): boolean => {
    const q = fileFilter().trim().toLowerCase();
    return !q || f.path.toLowerCase().includes(q);
  };
  // ⌘F may pop the file panel open just to filter. Remember if WE opened it, so dismissing the
  // filter (esc, or a 2nd ⌘F that hands off to native find) folds it back; if it was already open,
  // it stays open.
  let filterAutoOpenedPanel = false;
  const focusFilter = () => {
    if (!panelOpen()) {
      filterAutoOpenedPanel = true;
      setPanelOpen(true);
    }
    queueMicrotask(() => filterEl?.focus());
  };
  const restorePanel = () => {
    if (filterAutoOpenedPanel) {
      filterAutoOpenedPanel = false;
      setPanelOpen(false);
    }
  };
  return (
    <div class="shell" classList={{ "panel-collapsed": !panelOpen() }}>
      <Show when={!panelOpen()}>
        <button class="panel-reopen" title="show the file panel (b)" onClick={() => setPanelOpen(true)}>
          ›
        </button>
      </Show>
      <aside class="spine">
        <button
          class="panel-collapse"
          title="collapse the file panel for more diff width (b)"
          onClick={() => setPanelOpen(false)}
        >
          ‹
        </button>
        <Link class="brand" to={{ kind: "home", tab: "forests" }}>
          <span class="brand-mark">✦</span> blessed
        </Link>
        {/* the branch tree migrated to the docked map (the navigator); the spine is now the
            file list for the active branch. */}
        <Show when={spine().length} fallback={<div class="spine-empty">{project()}</div>}>
          <Show when={node.data} fallback={<div class="spine-meta">loading…</div>}>
            {(data) => (
              <>
                <div class="spine-meta">
                  {isGhost()
                    ? `${data().files.length} files · ✦ all changes`
                    : `${data().files.filter(isBlessed).length}/${data().files.length} files blessed`}
                </div>
                <Show
                  when={data().files.length}
                  fallback={<div class="spine-empty">nothing to review</div>}
                >
                  <input
                    class="file-filter"
                    ref={filterEl}
                    placeholder="filter files… (⌘F)"
                    value={fileFilter()}
                    onInput={(e) => setFileFilter(e.currentTarget.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Escape") {
                        e.preventDefault();
                        e.stopPropagation(); // don't let the global Esc fire (would jump to the map)
                        if (fileFilter()) { setFileFilter(""); } else { filterEl?.blur(); restorePanel(); }
                      } else if ((e.metaKey || e.ctrlKey) && e.key === "f") {
                        restorePanel(); // a 2nd ⌘F bubbles to native find; fold an auto-opened panel back
                      }
                    }}
                  />
                  <ul class="file-list">
                    <For each={data().files.filter(matchFilter)}>
                      {(f) => (
                        <li
                          class="file-item"
                          classList={{ blessed: isBlessed(f), active: activeFile() === f.path }}
                          onClick={() => scrollToFile(f.path)}
                          title={f.path}
                        >
                          <span class={`dot ${isBlessed(f) ? "blessed" : "unblessed"}`} />
                          <span class="file-item-name">{fileSeg(f.path)}</span>
                          <span class="file-item-lines">
                            <span class="add">+{f.add ?? 0}</span>
                            <span class="del">−{f.del ?? 0}</span>
                          </span>
                        </li>
                      )}
                    </For>
                  </ul>
                </Show>
              </>
            )}
          </Show>
        </Show>
      </aside>

      <main
        class="surface"
        onMouseOver={(e) => {
          const h = lineAt(e);
          // clear when off any row so `o` can't fire on a stale line; dedup to avoid churn
          setHover((prev) => (prev?.path === h?.path && prev?.line === h?.line ? prev : h));
        }}
        onMouseLeave={() => setHover(null)}
        onClick={(e) => {
          const h = lineAt(e);
          if (h) openInNvim(h.path, h.line);
        }}
      >
        <header class="node-head">
          {/* forest strip — forest altitude: which project + restack-forest. Lifted out of the
              branch control bar so forest-scope actions stop bleeding into branch controls. */}
          <div
            class="nh-forest"
            style={{
              display: "flex",
              "align-items": "center",
              gap: "10px",
              "padding-bottom": "10px",
              "border-bottom": "1px solid var(--rule)",
            }}
          >
            <Show
              when={location().kind === "forest"}
              fallback={
                <span
                  style={{
                    "font-size": "11px",
                    "letter-spacing": "0.07em",
                    "text-transform": "uppercase",
                    color: "var(--ink-faint)",
                  }}
                >
                  {project()}
                </span>
              }
            >
              <Link
                class="nh-forest-back"
                to={{ kind: "forest", name: project() }}
                title="back to the forest map — your current node stays highlighted there"
              >
                ⊞ {project()}
              </Link>
            </Show>
            <div class="nh-spacer" />
            <Show when={canMutate && unhealthy().length}>
              <button
                class="nh-fix"
                disabled={fixing()}
                title="restack this forest — rebases drifted nodes onto their parents and contracts merged ghosts (drop + rewire children). A conflict confined to a merged dep's files auto-resolves to what landed."
                onClick={fixForest}
              >
                {fixing()
                  ? fixProgress()?.total
                    ? `fixing… ${fixProgress()!.current ? fixProgress()!.current.split("/").pop() + " " : ""}${fixProgress()!.done}/${fixProgress()!.total}`
                    : "fixing…"
                  : `⟳ restack forest (${unhealthy().length})`}
              </button>
            </Show>
            <Show when={fixResult()}>
              <span
                title={fixResult()!.ok ? "" : fixResult()!.msg}
                style={{
                  "font-size": "11px",
                  "letter-spacing": ".03em",
                  "white-space": "nowrap",
                  color: fixResult()!.ok ? "var(--gold-leaf)" : "var(--del)",
                }}
              >
                {fixResult()!.msg}
              </span>
            </Show>
          </div>
          {/* branch strip — identity: the branch name + what it's diffed against + health badges. */}
          <div class="nh-id">
            <h1>{isGhost() ? `✦ ${project()}` : leaf(active()) || "—"}</h1>
            <Show
              when={isGhost()}
              fallback={
                <Show when={parentOf()}>
                  <span class="against">◂ {leaf(parentOf())}</span>
                </Show>
              }
            >
              <span class="against">◂ main · all changes on this project</span>
            </Show>
            <Show when={!isGhost() && nodeHealth(active())?.drifted}>
              <span
                class="nh-drift"
                title={`off its parent (${nodeHealth(active())?.parent ?? "?"}) — that branch isn't a git ancestor, so this 'diff vs parent' is effectively the diff vs main. Restack the forest to separate it.`}
              >
                ⤺ off-parent · diff ≈ vs main
              </span>
            </Show>
            <Show when={!isGhost() && nodeHealth(active())?.merged}>
              <span class="nh-ghost" title="this branch's work already landed in main (a ghost) — restack to contract it (drop + rewire its children)">
                ✦ merged — ghost
              </span>
            </Show>
            <Show when={!isGhost() && nodeHealth(active())?.upstreamBad}>
              <span class="nh-drift" title={nodeHealth(active())?.upstreamReason}>
                ⚠ tracks {leaf(nodeHealth(active())!.upstream!)}
                <Show when={(nodeHealth(active())?.ahead || nodeHealth(active())?.behind)}>
                  {" "}({nodeHealth(active())?.ahead ?? 0}↑ {nodeHealth(active())?.behind ?? 0}↓)
                </Show>
                <button
                  class="nh-fix"
                  style={{ "margin-left": "8px" }}
                  disabled={detachUpstream.isPending}
                  title="unset this tracking ref so a Pull/Push can't merge the wrong remote in — keeps every commit"
                  onClick={() => detachUpstream.mutate(active())}
                >
                  {detachUpstream.isPending ? "detaching…" : "detach"}
                </button>
              </span>
            </Show>
            <Show when={!isGhost() && nodeHealth(active())?.diverged}>
              <span
                class="nh-drift"
                title={`local diverged from its pushed PR head ${leaf(nodeHealth(active())!.upstream!)} (${nodeHealth(active())?.ahead ?? 0}↑ ${nodeHealth(active())?.behind ?? 0}↓) — almost always a local rebase the pushed head hasn't caught. Don't Pull (it re-adds the stale commits); hand it to Claude to reconcile.`}
              >
                ⇄ diverged from {leaf(nodeHealth(active())!.upstream!)} ({nodeHealth(active())?.ahead ?? 0}↑ {nodeHealth(active())?.behind ?? 0}↓)
                <button
                  class="nh-fix"
                  style={{ "margin-left": "8px" }}
                  disabled={reconcile.isPending}
                  title="eject a standalone Claude in this branch's worktree to work out the source of truth and reconcile — no force-push, no blind pull"
                  onClick={() => reconcile.mutate(active())}
                >
                  {reconcile.isPending ? "ejecting…" : "reconcile"}
                </button>
              </span>
            </Show>
          </div>
          {/* tier 2 — controls: view switches on the left, branch state + actions on the right.
              The blessed count lives in the spine; the map opens from the spine + `m`. */}
          <div class="nh-bar">
            <div class="view-toggle">
              <button class="view-pill" classList={{ on: view() === "diffs" }} onClick={() => setView("diffs")}>
                diffs
              </button>
              <button class="view-pill" classList={{ on: view() === "commits" }} onClick={() => setView("commits")}>
                commits
              </button>
            </div>
            <Show when={view() === "diffs" && !isGhost()}>
              <div class="base-toggle">
                <span class="base-label">diff vs</span>
                <For each={BASES}>
                  {([v, lab]) => (
                    <button class="base-pill" classList={{ on: base() === v }} onClick={() => setBase(v)}>
                      {lab}
                    </button>
                  )}
                </For>
              </div>
            </Show>
            <div class="nh-spacer" />
            <Show when={!isGhost()}>
              <NodeActions branch={active()} isReview={location().kind === "review"} />
            </Show>
            <Show when={canMutate}>
              <button class="icon-btn" onClick={() => openChat({ branch: active(), origin: location(), file: null })} title="chat about this whole branch">
                ✦
              </button>
            </Show>
            <button class="icon-btn" onClick={() => setShowChats(true)} title="all chat threads across the forest">
              💬
            </button>
          </div>
        </header>
        <Show when={view() === "diffs"} fallback={<CommitsList q={commits} />}>
          <div class="diff-hint">
            <span class="kbd-hint"><b>tab</b> next file · <b>b</b> files · <b>⌘F</b> filter · <b>?</b> shortcuts</span>
          </div>
          <Show when={node.data} fallback={<p class="loading">loading…</p>}>
            {(data) => (
              <Show when={data().files.length} fallback={<p class="loading">nothing to review here ✦</p>}>
                <Show when={data().files.filter(matchFilter).length} fallback={<p class="loading">no files match “{fileFilter()}”</p>}>
                  <For each={data().files.filter(matchFilter)}>
                    {(f) => <FileEntry file={f} bless={bless} branch={active()} readOnly={isGhost()} onChat={(file) => openChat({ branch: active(), origin: location(), file })} />}
                  </For>
                </Show>
              </Show>
            )}
          </Show>
        </Show>
      </main>
      <Show when={canMutate}>
        <AskClaudeChip selection={claudeSel} branch={active} onClear={clearClaudeSel} />
      </Show>
      <Show when={showChats()}>
        <ChatIndex onClose={() => setShowChats(false)} onOpen={openChatInContext} />
      </Show>
      <Show when={showHelp()}>
        <div class="kbd-help-scrim" onClick={() => setShowHelp(false)}>
          <div class="kbd-help" onClick={(e) => e.stopPropagation()}>
            <div class="kbd-help-head">keyboard · reviewing a branch</div>
            <dl>
              <div><dt><span class="k">j</span><span class="k">k</span></dt><dd>previous / next branch</dd></div>
              <div><dt><span class="k">tab</span></dt><dd>next file</dd></div>
              <div><dt><span class="k">b</span></dt><dd>show / hide the file panel</dd></div>
              <div><dt><span class="k">⌘F</span></dt><dd>filter files</dd></div>
              <div><dt><span class="k">⇧B</span></dt><dd>bless file &amp; advance</dd></div>
              <div><dt><span class="k">⇧U</span></dt><dd>unbless file</dd></div>
              <div><dt><span class="k">1</span><span class="k">2</span><span class="k">3</span></dt><dd>base: branch / main / blessed</dd></div>
              <div><dt><span class="k">c</span></dt><dd>commits ↔ diffs</dd></div>
              <div><dt><span class="k">o</span></dt><dd>open hovered line in nvim</dd></div>
              <div><dt><span class="k">esc</span></dt><dd>up to the forest map</dd></div>
              <div><dt><span class="k">?</span></dt><dd>this help</dd></div>
            </dl>
          </div>
        </div>
      </Show>
      <style>{NODE_KBD_CSS}</style>
      <Show when={flash()}>
        <div class="flash">{flash()}</div>
      </Show>
    </div>
  );
}

function FileEntry(props: {
  file: FileDiff;
  bless: { mutate: (file: string) => void };
  branch: string;
  readOnly?: boolean;
  onChat: (f: FileDiff) => void;
}) {
  const [foil, setFoil] = createSignal(false);
  const [copied, setCopied] = createSignal(false);
  const blessed = () => isBlessed(props.file);
  // a blessed file starts collapsed — it's reviewed with nothing new since (a changed-since-
  // blessed file reads as 'stale', not blessed), so it shouldn't cost screen space. Stale and
  // unblessed files start open.
  const [collapsed, setCollapsed] = createSignal(blessed());
  const chatWorking = () => threadWorking(props.branch, props.file.path);
  const chatUnseen = () => threadUnseenDone(props.branch, props.file.path);
  const doBless = () => {
    setFoil(true); // play the foil on the click — feels instant; the steady gold lands on refetch
    props.bless.mutate(props.file.path);
    setTimeout(() => setFoil(false), 750);
  };
  // Copy a paste-ready reference for dropping the file into a Claude conversation.
  const copyRef = async () => {
    try {
      await navigator.clipboard.writeText(`\`${props.file.path}\` (on branch \`${props.branch}\`)`);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      /* clipboard blocked (insecure origin / denied) — silently no-op */
    }
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
        <button
          class="entry-toggle"
          title={collapsed() ? "expand" : "collapse"}
          onClick={() => setCollapsed((c) => !c)}
        >
          {collapsed() ? "▸" : "▾"}
        </button>
        <span class="gutter">{blessed() || foil() ? "✦" : ""}</span>
        <span class="path" onClick={() => setCollapsed((c) => !c)}>{seg(props.file.path)}</span>
        <span class="lines">
          <span class="add">+{props.file.add ?? 0}</span>
          <span class="del">−{props.file.del ?? 0}</span>
        </span>
        <button
          class="file-act"
          title="copy a paste-ready file + branch reference for a Claude conversation"
          onClick={copyRef}
        >
          {copied() ? "copied ✓" : "⎘ copy ref"}
        </button>
        <Show when={threadMsgCount(props.branch, props.file.path) > 0}>
          <span class="chat-badge" title="this file has a chat thread">
            💬 {threadMsgCount(props.branch, props.file.path)}
          </span>
        </Show>
        <Show when={canMutate}>
          <button
            class="file-act chat-act"
            classList={{ working: chatWorking(), done: !chatWorking() && chatUnseen() }}
            title={
              chatWorking()
                ? "Claude is still answering on this file — click to watch"
                : chatUnseen()
                  ? "Claude finished while the drawer was closed — click to read"
                  : "chat about this file with Claude — streamed right here"
            }
            onClick={() => props.onChat(props.file)}
          >
            {chatWorking() ? "✦ working…" : chatUnseen() ? "✦ done ✓" : "✦ chat"}
          </button>
          <Show when={!props.readOnly}>
            <button class="bless-btn" disabled={blessed()} onClick={doBless}>
              {blessed() ? "blessed" : "bless ✦"}
            </button>
          </Show>
        </Show>
      </div>
      <Show when={!collapsed()}>
        <div class="diff" innerHTML={html()} />
      </Show>
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
