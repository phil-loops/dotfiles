import {
  createSignal,
  createMemo,
  createEffect,
  on,
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
import { RouterProvider, useViewerLocation, Link, forestKey, withNode, forestRepo, type HomeTab, type ViewerLocation } from "./router";
import { ActionBar, type Action } from "./actions";
import * as Diff2Html from "diff2html";
import { ColorSchemeType } from "diff2html/lib/types";
import { provider, canMutate, withRepo } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { NodeActions } from "./NodeActions";
import { ForestMap } from "./ForestMap";
import MergeStory from "./MergeStory";
import { overviewView, setOverviewView } from "./overviewView";
import ChatPanel from "./ChatPanel";
import ChatIndex from "./ChatIndex";
import { chatTarget, openChat, closeChat, chatToTmux } from "./chatDrawer";
import { threadMsgCount, threadWorking, threadUnseenDone } from "./chatStore";
import { reconcile as reconcileChats } from "./chatRunner";
import { useFileCycle } from "./useFileCycle";
import CommandPalette from "./CommandPalette";
import { track, installFetchTracking, installUiTracking } from "./track";
import { ServerStatus } from "./ServerStatus";
import { Hearth } from "./Hearth";
import { Activity } from "./Activity";
import MobilePush from "./MobilePush";
import type {
  ForestModel,
  SpineNode,
  FileDiff,
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

// compact interest indicator: ▲ per level, capped at 5 with a trailing + (exact n on hover).
function interestPips(n: number): string {
  if (!n || n <= 0) return "";
  return "▲".repeat(Math.min(n, 5)) + (n > 5 ? "+" : "");
}

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
      <Activity />
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
        project={chatTarget()?.project}
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
  // live chat presence — server truth (srv/chat.py's job registry), not this browser's
  // localStorage, so chats started in another tab (or surviving a closed one) still show.
  type ChatJob = {
    turn: string; branch: string; path: string; question: string; repo: string; project: string;
    status: string; chars: number; done: boolean; ok: boolean | null; created: number;
  };
  const chatJobs = createQuery(() => ({
    queryKey: ["chat-jobs"],
    queryFn: () => fetch("/chat-jobs").then((r) => r.json() as Promise<ChatJob[]>),
    refetchInterval: 5_000,
  }));
  const liveChats = createMemo(() => (chatJobs.data || []).filter((j) => !j.done));
  // a finished chat lingers in the strip briefly as "done ✓" so an answer that landed while you
  // were elsewhere gets seen; the server's own TTL bounds it, this just tightens the window.
  const stripChats = createMemo(() =>
    (chatJobs.data || []).filter((j) => !j.done || Date.now() - j.created * 1000 < 15 * 60_000));
  const chatTarget = (j: ChatJob): ViewerLocation =>
    j.project
      ? { kind: "forest", name: j.project, repo: j.repo || undefined, node: j.branch }
      : { kind: "forest", name: j.branch, repo: j.repo || undefined };
  const fmtChars = (n: number) => (n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n));
  const chatAgo = (createdSec: number) => {
    const s = Math.max(0, Math.floor(Date.now() / 1000 - createdSec));
    return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 3600)}h`;
  };
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

  // the ambient daemon's dry-run forest verdict (scripts/restack-daemon) → one quiet chip
  const ambient = createQuery(() => ({
    queryKey: ["restack-ambient"],
    queryFn: () => provider.restackAmbient(),
    refetchInterval: 15000,
  }));
  // collapse the summary to the single most-urgent signal: a real conflict outranks an
  // already-merged ghost outranks pending restacks; all-zero behind = the forest is clean.
  const ambientChip = (): { cls: string; text: string; title: string } | null => {
    const a = ambient.data;
    if (!a?.available || !a.report) return null;
    const s = a.report.summary;
    const stale = (a.age_s ?? 0) > 3600; // daemon hasn't refreshed in >1h → don't trust it
    const age = a.age_s == null ? "" : a.age_s < 90 ? "just now"
      : a.age_s < 3600 ? `${Math.round(a.age_s / 60)}m ago` : `${Math.round(a.age_s / 3600)}h ago`;
    let title = `dry-run @ ${age}: ${s.clean} clean · ${s.would_restack} would-restack · `
      + `${s.would_contract} merged · ${s.will_conflict} will-conflict · ${s.skipped} skipped (moves nothing)`;
    // name the culprits so the alarm is actionable, not just a count
    const conflicts = a.report.branches.filter((b) => b.verdict === "will-conflict");
    if (conflicts.length) {
      title += "\n\nwill conflict:\n" + conflicts
        .map((b) => `  ${b.branch}${b.conflict_pr ? ` → #${b.conflict_pr} ${b.conflict_title ?? ""}` : ""}`)
        .join("\n");
    }
    const ghosts = a.report.branches.filter((b) => b.verdict === "would-contract");
    if (ghosts.length) {
      title += "\n\nalready merged — click drops each & rewires its children:\n"
        + ghosts.map((b) => `  ${b.branch}`).join("\n");
    }
    if (stale) return { cls: "amb-stale", text: "✦ daemon idle", title };
    if (s.will_conflict > 0) return { cls: "amb-conflict", text: `⚠ ${s.will_conflict} will conflict`, title };
    if (s.would_contract > 0) return { cls: "amb-contract", text: `⊘ ${s.would_contract} merged — drop?`, title };
    if (s.would_restack > 0) return { cls: "amb-restack", text: `⟳ ${s.would_restack} would restack`, title };
    return { cls: "amb-clean", text: "✦ forest clean", title };
  };

  // the ⊘ chip's fix: drop every already-merged ghost the daemon found. Each POST /contract
  // re-verifies merged-ness server-side (409 otherwise), so a stale report can't drop real work.
  const dropGhosts = createMutation(() => ({
    mutationFn: async () => {
      const ghosts = (ambient.data?.report?.branches ?? []).filter((b) => b.verdict === "would-contract");
      for (const g of ghosts) {
        await fetch("/contract", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ branch: g.branch }),
        }).then((r) => r.json());
      }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["restack-ambient"] });
      qc.invalidateQueries({ queryKey: ["projects"] });
    },
  }));

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
  // right-click a forest card → set its importance (stack-project.<name>.interest) — what
  // floats the forest up the Home list.
  const [ctxMenu, setCtxMenu] = createSignal<
    { x: number; y: number; repo: string; project: string; current: number } | null
  >(null);
  const setInterest = createMutation(() => ({
    mutationFn: (arg: { repo: string; project: string; value: number }) =>
      fetch(`/${arg.repo}/interest`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project: arg.project, value: arg.value }),
      }).then((r) => r.json()),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["projects"] }),
  }));

  const { location, navigate } = useViewerLocation();
  const tab = (): HomeTab => {
    const l = location();
    return l.kind === "home" ? l.tab : "work";
  };
  const [forestQuery, setForestQuery] = createSignal("");
  // Forests recency — one opinionated order, no sort knobs (Phil, 2026-07-05, third strike
  // on option-proliferation). "Most recently alive": the latest of local commit, PR opened,
  // and merge-to-main. The individual timestamps stay as passive per-card metadata.
  const forestTs = (p: Project): number =>
    Math.max(
      (p.lastCommit ?? 0) * 1000,
      p.prOpened ? Date.parse(p.prOpened) : 0,
      p.merged?.at ? Date.parse(p.merged.at) : 0,
    );

  // hover a forest row → a card of its branches + one-line purposes ("what's in here").
  // cached per project; a short delay keeps it from flickering as the pointer crosses rows.
  type FPurpose = { branch: string; thesis: string };
  const [ftip, setFtip] = createSignal<{ rows: FPurpose[]; landed: Project["landed"]; x: number; y: number } | null>(null);
  const fpCache = new Map<string, FPurpose[]>();
  let ftipFor: string | null = null;
  let ftipTimer: ReturnType<typeof setTimeout> | undefined;
  const showFtip = (project: string, el: HTMLElement, repo?: string, landed?: Project["landed"]) => {
    clearTimeout(ftipTimer);
    ftipFor = project;
    const r = el.getBoundingClientRect();
    const place = (rows: FPurpose[]) => {
      if (ftipFor !== project || (!rows.length && !landed?.length)) return;
      const estH = 18 + rows.length * 44 + (landed?.length ? 12 + landed.length * 18 : 0);
      // flip above the row when there isn't room below, so the card stays on-screen
      const y = window.innerHeight - r.bottom >= estH + 12 ? r.bottom + 6 : Math.max(8, r.top - estH - 6);
      setFtip({ rows, landed, x: r.left + 18, y });
    };
    const key = (repo && repo !== "loops" ? repo + "/" : "") + project; // repo-qualify so names don't collide across repos
    const cached = fpCache.get(key);
    if (cached) {
      ftipTimer = setTimeout(() => place(cached), 160);
      return;
    }
    // the home list spans repos and isn't pinned to one, so prefix the hovered forest's repo here.
    const prefix = repo && repo !== "loops" ? "/" + encodeURIComponent(repo) : "";
    ftipTimer = setTimeout(() => {
      fetch(prefix + "/forest-purposes?project=" + encodeURIComponent(project))
        .then((res) => res.json() as Promise<FPurpose[]>)
        .then((rows) => { fpCache.set(key, rows); place(rows); })
        .catch(() => {});
    }, 160);
  };
  const hideFtip = () => { clearTimeout(ftipTimer); ftipFor = null; setFtip(null); };

  // declared before the work-tab memos below: createMemo runs eagerly, so a warm prs cache makes
  // them call forestOf during render — a later `const` would hit its temporal dead zone and throw.
  const forestOf = (name: string): Project | undefined => (projects.data || []).find((p) => p.name === name);

  // A PR whose own forest reports it merged is "landed", not open — the merge fact lives on the
  // forest (Project.merged), never on the PR, so without this merged PRs leak into the open list.
  const mergedOf = (p: PR) => {
    const m = forestOf(p.project)?.merged;
    return m && (m.pr === p.num || m.branch === p.branch) ? m : undefined;
  };
  const landedRecently = (p: PR): boolean => {
    const m = mergedOf(p);
    if (!m) return false;
    const at = Date.parse(m.at);
    return Number.isFinite(at) && Date.now() - at < 24 * 3_600_000;
  };
  // one lifecycle state per row — drives the status-rail colour (the "blessing spine").
  type WorkState = "changes" | "review" | "pending" | "draft" | "landed";
  const prState = (p: PR): WorkState =>
    landedRecently(p) ? "landed"
    : p.review === "CHANGES_REQUESTED" ? "changes"
    : p.review === "APPROVED" ? "review"
    : p.draft ? "draft"
    : "pending";

  // Work tab partitions: what needs you (changes requested) → what's in flight (open, by
  // forest) → what just landed (merged < 1d, then it drops off on its own).
  const needsYouPRs = createMemo(() =>
    (prs.data || []).filter((p) => !landedRecently(p) && p.review === "CHANGES_REQUESTED"));
  const inFlightByProject = createMemo<[string, PR[]][]>(() => {
    const m = new Map<string, PR[]>();
    for (const p of prs.data || []) {
      if (landedRecently(p) || p.review === "CHANGES_REQUESTED") continue;
      const k = p.project || "—";
      (m.get(k) ?? m.set(k, []).get(k)!).push(p);
    }
    return [...m.entries()];
  });
  const landedPRs = createMemo(() => (prs.data || []).filter(landedRecently));
  // one verdict per in-flight forest, replacing the 4-fact comma run in the old header.
  const forestVerdict = (proj: string, list: PR[]): { label: string; state: WorkState } => {
    const f = forestOf(proj);
    if (list.some((p) => p.review === "APPROVED")) return { label: "in review", state: "review" };
    if (f && f.behind > 60) return { label: `${f.behind} behind · stale`, state: "changes" };
    if (list.every((p) => p.draft)) return { label: "draft", state: "draft" };
    return { label: "open", state: "pending" };
  };

  // the trailing slot of a work row — a landed row reads "forest · ago ✓"; everything else keeps
  // the review mark (▲ changes / ✓ approved / • pending) and a draft tag when relevant.
  const workRowTrail = (p: PR) => {
    if (landedRecently(p)) {
      const m = mergedOf(p)!;
      return (
        <>
    <span class="work-meta">{p.project} · {mergedAgo(m.at)}</span>
          <span class="pr-rev ok">✓</span>
        </>
      );
    }
    const [mark, cls] = review(p.review);
    return (
      <>
{p.draft && <span class="pr-draft">draft</span>}
        <span class={`pr-rev ${cls}`}>{mark}</span>
      </>
    );
  };

  // one work row, state-rail on the left. Forest-backed PRs route in-app and carry recessive
  // hover actions; a bare PR is itself the GitHub link, so it needs no action bar.
  const workRow = (p: PR) => {
    const state = prState(p);
    const body = (
      <>
        <span class="pr-num">#{p.num}</span>
        <span class="pr-title">{p.title}</span>
        {workRowTrail(p)}
      </>
    );
    return p.project ? (
      <div class={`work-row work-state-${state}`}>
        <Link class="work-link" to={{ kind: "forest", name: p.project, node: p.branch }}>{body}</Link>
        <Show when={state !== "landed"}>
          <span class="work-acts"><ActionBar actions={workRowActions(p)} /></span>
        </Show>
      </div>
    ) : (
      <a class={`work-row work-state-${state}`} href={p.url} target="_blank">{body}</a>
    );
  };

  // the open PR for a forest, if any — drives the [PR #N] badge so a PR'd forest stays in the
  // Forests list (the complete index) instead of vanishing the moment it gets a PR.
  const prOf = (name: string): PR | undefined => (prs.data || []).find((p) => p.project === name);

  const filteredForests = createMemo(() => {
    const needle = forestQuery().trim().toLowerCase();
    const list = projects.data || [];
    return needle ? list.filter((p) => p.name.toLowerCase().includes(needle)) : list;
  });
  // A forest folds into "recently merged" only once it's fully wrapped up: a recent merge AND no
  // mergeable roots left (every branch landed AND got contracted). A forest where one base merged
  // but others are still open/unpushed keeps mergeable roots, so it stays in the active list —
  // that's the moment to restack and ship the rest, not bury it. (mergeable still lists squash-
  // merged-but-uncontracted roots, so a just-merged forest lingers in active until you contract it.)
  const recentlyMerged = (p: Project): boolean =>
    !!(p.merged && mergedAgo(p.merged.at)) && !p.mergeable?.length;
  // Group the home list by repo (loops first, then alphabetical), then within each repo split the
  // active forests into PRIORITY TIERS (interest level, descending) so same-priority work stands
  // together, and pull recently-merged forests aside into their own fold.
  const forestGroups = createMemo(() => {
    const by = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      const r = p.repo || "loops";
      (by.get(r) ?? by.set(r, []).get(r)!).push(p);
    }
    return [...by.entries()]
      .sort(([a], [b]) => (a === "loops" ? -1 : b === "loops" ? 1 : a.localeCompare(b)))
      .map(([repo, items]) => {
        const merged = items.filter(recentlyMerged).sort((a, b) => forestTs(b) - forestTs(a));
        const active = items.filter((p) => !recentlyMerged(p));
        const levels = [...new Set(active.map((p) => p.interest ?? 0))].sort((a, b) => b - a);
        const tiers = levels.map((interest) => ({
          interest,
          // within a tier, most-recently-alive first (blended commit/PR/merge recency).
          items: active
            .filter((p) => (p.interest ?? 0) === interest)
            .sort((a, b) => forestTs(b) - forestTs(a)),
        }));
        return { repo, tiers, merged };
      });
  });
  const multiRepo = createMemo(() => forestGroups().length > 1);
  // recently-merged fold is collapsed per repo until clicked.
  const [mergedOpenSet, setMergedOpenSet] = createSignal<Set<string>>(new Set());
  const mergedOpen = (r: string) => mergedOpenSet().has(r);
  const toggleMerged = (r: string) =>
    setMergedOpenSet((s) => {
      const n = new Set(s);
      if (n.has(r)) { n.delete(r); } else { n.add(r); }
      return n;
    });
  const workCount = () => (prs.data || []).length + (reviewReqs.data || []).length;

  // NEXT — one ranked queue of concrete next actions, so you hop in at the top instead of
  // triaging buckets. Pure function of signals already on hand: PR review/ci/mergeState,
  // forest merged/behind/prOpened, and review-requested-of-you. Tier sets the order; each row
  // carries a one-line WHY (the thing that justifies the rank) and a one-click target.
  type NextAction = {
    id: string; tier: number; tone: string; icon: string; verb: string;
    target: string; why: string; title?: string;
    href?: string; to?: ViewerLocation;
  };
  const STALE_BEHIND = 60; // a forest this far behind is rot to decide on, not work to open
  const nextActions = createMemo<NextAction[]>(() => {
    const out: NextAction[] = [];
    const prList = prs.data || [];
    const projs = projects.data || [];
    const blockedMerge = (s?: string) => s === "BLOCKED" || s === "DIRTY";
    const tag = (p: PR) => `#${p.num}${p.project ? " " + p.project : " " + leaf(p.branch)}`;
    for (const p of prList) {
      if (p.draft || landedRecently(p)) continue;
      if (p.review === "APPROVED" && p.ci === "passing" && !blockedMerge(p.mergeState)) {
        out.push({ id: "merge:" + p.num, tier: 0, tone: "ship", icon: "⬆", verb: "merge",
          target: tag(p), why: "approved · CI green", title: p.title, href: p.url });
      } else if (p.review === "APPROVED" && (p.ci === "failing" || blockedMerge(p.mergeState))) {
        out.push({ id: "unblock:" + p.num, tier: 1, tone: "block",
          icon: p.ci === "failing" ? "↻" : "⚠", verb: p.ci === "failing" ? "fix CI" : "unblock",
          target: tag(p), why: p.ci === "failing" ? "approved · CI failing" : "approved · merge blocked",
          title: p.title, href: p.url });
      }
    }
    const hasPR = new Set(prList.filter((p) => p.project).map((p) => p.project));
    for (const pr of projs) {
      const loc: ViewerLocation = { kind: "forest", name: pr.name, repo: pr.repo };
      if (pr.merged) {
        out.push({ id: "contract:" + pr.name, tier: 3, tone: "contract", icon: "✂",
          verb: "contract", target: pr.name, why: "merged · node lingering", to: loc });
      } else if (!pr.prOpened && !hasPR.has(pr.name) && pr.mergeable?.length && pr.behind < STALE_BEHIND) {
        out.push({ id: "open:" + pr.name, tier: 2, tone: "open", icon: "↗", verb: "open PR",
          target: pr.name, why: pr.behind > 0 ? `${pr.behind} behind · no PR yet` : "clean · no PR yet", to: loc });
      } else if (!pr.merged && pr.behind >= STALE_BEHIND) {
        out.push({ id: "decide:" + pr.name, tier: 5, tone: "decide", icon: "✦",
          verb: "decide", target: pr.name, why: `${pr.behind} behind · revive or drop`, to: loc });
      }
    }
    for (const r of reviewReqs.data || []) {
      out.push({ id: "review:" + r.number, tier: 4, tone: "review", icon: "\u{1F441}",
        verb: "review", target: `#${r.number}`, why: `requested of you · @${r.author}`,
        title: r.title, href: r.url });
    }
    return out.sort((a, b) => a.tier - b.tier);
  });
  const nextRowBody = (a: NextAction) => (
    <>
      <span class="nq-icon">{a.icon}</span>
      <span class="nq-verb">{a.verb}</span>
      <span class="nq-target">{a.target}</span>
      <span class="nq-why">{a.why}</span>
    </>
  );

  const review = (r?: string | null): [string, string] =>
    r === "APPROVED" ? ["✓", "ok"] : r === "CHANGES_REQUESTED" ? ["▲", "chg"] : ["•", "req"];

  const restacking = (name: string) => () => running() === name || running() === "__all__";
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

  const githubAction = (url: string, branch: string): Action => ({
    id: "gh:" + branch,
    title: "open on GitHub",
    label: () => "↗ GitHub",
    run: () => window.open(url, "_blank"),
  });
  // GitHub link only — the worktree reveal moved to the node ⋯ menu (telemetry trim:
  // ≤4 uses in 10d didn't earn a pill on every work row).
  const workRowActions = (p: PR): Action[] => [githubAction(p.url, p.branch)];

  // one forest row, shared by the priority tiers and the recently-merged fold. Metadata sits in
  // fixed-width cells (pips · nodes · PR) so the columns line up down the list; the trailing cell
  // hugs the right edge. `folded` rows swap the behind/restack trail for a static ✨-merged badge.
  const forestRow = (p: Project, folded: boolean) => {
    const stuck = () => parked()?.project === p.name;
    return (
      <Link
        class="forest-row"
        classList={{ parked: stuck(), folded }}
        to={{
          kind: "forest",
          name: p.name,
          repo: p.repo,
          node: p.repo !== "loops" ? (p.mergeable?.[0] ?? p.candidates?.[0]) : undefined,
        }}
        onMouseEnter={(e) => showFtip(p.name, e.currentTarget as HTMLElement, p.repo, p.landed)}
        onMouseLeave={hideFtip}
        onContextMenu={(e) => {
          if (!canMutate) return;
          e.preventDefault();
          hideFtip();
          setCtxMenu({ x: e.clientX, y: e.clientY, repo: p.repo, project: p.name, current: p.interest ?? 0 });
        }}
      >
        <span class={`forest-dot ${stuck() ? "parked" : p.behind > 0 ? "behind" : "fresh"}`} />
        <span class="forest-name">{p.name}</span>
        <Show when={liveChats().some((j) => (j.project || j.branch) === p.name && (!j.repo || j.repo === p.repo))}>
          <span class="forest-chat" title="a chat is running on this forest">✦</span>
        </Show>
        {/* ONE status cell, by precedence (Phil, strike 5: "a row = name + one signal") —
            drop-mode > parked repair > merged fold > behind count > open PR. Pips live on
            the tier header, node count on the overview; no signal at all = fresh. */}
        <span class="fcell trail">
          <Switch
            fallback={
              <Show when={prOf(p.name)}>
                {(pr) => (
                  <span class="forest-pr" classList={{ draft: pr().draft }} title={pr().title}>
                    {pr().draft ? "draft" : "PR"} #{pr().num}
                  </span>
                )}
              </Show>
            }
          >
            <Match when={deleteMode() && canMutate}>
              <ActionBar actions={[dropAction(p)]} />
            </Match>
            <Match when={stuck()}>
              <div class="forest-parked">
                <button
                  class="forest-resolve"
                  classList={{ open: menu() === p.name }}
                  onClick={(e) => { e.preventDefault(); e.stopPropagation(); setMenu(menu() === p.name ? null : p.name); }}
                >
                  ⚠ parked at {leaf(parked()?.current || p.name)}
                </button>
                <Show when={menu() === p.name}>
                  <div class="forest-popover" onClick={(e) => { e.preventDefault(); e.stopPropagation(); }}>
                    <p class="forest-popover-why">
                      Rebase paused on a conflict{parked()?.current ? ` rebasing ${leaf(parked()!.current)}` : ""}. It holds a worktree and blocks restacks until it’s cleared.
                    </p>
                    <Show when={parked()?.reason}>{(r) => <p class="forest-popover-reason">{r()}</p>}</Show>
                    <div class="forest-popover-actions">
                      <button onClick={(e) => { e.preventDefault(); e.stopPropagation(); resolve(p.name); }}>✦ resolve with Claude</button>
                      <button class="danger" onClick={(e) => { e.preventDefault(); e.stopPropagation(); abort(p.name); }}>✕ abort & discard</button>
                    </div>
                  </div>
                </Show>
              </div>
            </Match>
            <Match when={folded}>
              <Show when={p.merged && mergedAgo(p.merged.at)}>
                {(rel) => (
                  <span class="forest-merged" title={p.merged!.title}>
                    ✨ {(p.landed?.length ?? 0) > 1 ? `${p.landed!.length} landed · ${rel()}` : `${rel()} (#${p.merged!.pr})`}
                  </span>
                )}
              </Show>
            </Match>
            <Match when={p.behind > 0}>
              <span class="forest-trail">⟳ {p.behind} behind</span>
            </Match>
          </Switch>
        </span>
      </Link>
    );
  };

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
          <Show when={ambientChip()}>
            {(c) => (
              <Show
                when={c().cls === "amb-contract" && canMutate}
                fallback={<span class={`amb-chip ${c().cls}`} title={c().title}>{c().text}</span>}
              >
                <button
                  class="amb-chip amb-contract amb-act"
                  title={c().title}
                  disabled={dropGhosts.isPending}
                  onClick={() => dropGhosts.mutate()}
                >
                  {dropGhosts.isPending ? "⊘ dropping…" : c().text}
                </button>
              </Show>
            )}
          </Show>
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

      <Show when={stripChats().length}>
        <section class="work-sec chat-live">
          <h2 class="eyebrow">chats <span class="eyebrow-ask">— headless claudes on your branches</span></h2>
          <div class="work-rule" />
          <For each={stripChats()}>
            {(j) => (
              <Link class="chat-row" classList={{ done: j.done }} to={chatTarget(j)} title={j.question}>
                <span class={`chat-mark ${j.done ? (j.ok === false ? "err" : "ok") : "live"}`}>✦</span>
                <span class="chat-branch">{leaf(j.branch)}</span>
                <span class="chat-file">{j.path ? leaf(j.path) : "whole branch"}</span>
                <span class="chat-progress">
                  {j.done ? (j.ok === false ? "✗ failed" : "done ✓") : `${j.status}…`} · {fmtChars(j.chars)} · {chatAgo(j.created)}
                </span>
              </Link>
            )}
          </For>
        </section>
      </Show>

      <Show when={tab() === "work" && nextActions().length}>
        <section class="work-sec next-queue">
          <h2 class="eyebrow">next <span class="eyebrow-ask">— what to do, ranked</span></h2>
          <div class="work-rule" />
          <For each={nextActions()}>
            {(a) =>
              a.to ? (
                <Link class={`nq-row nq-${a.tone}`} to={a.to} title={a.title}>
                  {nextRowBody(a)}
                </Link>
              ) : (
                <a class={`nq-row nq-${a.tone}`} href={a.href} target="_blank" rel="noopener" title={a.title}>
                  {nextRowBody(a)}
                </a>
              )
            }
          </For>
        </section>
      </Show>

      <Show when={tab() === "work" && needsYouPRs().length}>
        <section class="work-sec">
          <h2 class="eyebrow">needs you <span class="eyebrow-ask">— blocked or waiting on your call</span></h2>
          <div class="work-rule" />
          <For each={needsYouPRs()}>{(p) => workRow(p)}</For>
        </section>
      </Show>

      <Show when={tab() === "work" && (reviewReqs.data || []).length}>
        <section class="work-sec">
          <h2 class="eyebrow">review requests <span class="eyebrow-ask">— teammates waiting on your review</span></h2>
          <div class="work-rule" />
          <For each={reviewReqs.data}>
            {(r) => {
              const importing = () => importReview.isPending && importReview.variables === r.number;
              const body = (
                <>
                  <span class="pr-num">#{r.number}</span>
                  <span class="pr-title">{r.title}</span>
                  <span class="work-meta">@{r.author}</span>
                </>
              );
              return (
                <div class="work-row work-state-review">
                  {r.imported ? (
                    <Link class="work-link" to={{ kind: "review", pr: r.number }}>{body}</Link>
                  ) : (
                    <a class="work-link" href={r.url} target="_blank">{body}</a>
                  )}
                  {/* import is the primary act here + "on viewer ✓" is at-a-glance status, so both
                      stay visible (not folded into the hover-recessive work-acts the PR rows use). */}
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

      <Show when={tab() === "work" && inFlightByProject().length}>
        <section class="work-sec">
          <h2 class="eyebrow">in flight <span class="eyebrow-ask">— your open work, by forest</span></h2>
          <div class="work-rule" />
          <For each={inFlightByProject()}>
            {([proj, list]) => {
              const v = forestVerdict(proj, list);
              return (
                <>
                  <div class={`work-forest work-state-${v.state}`}>
                    <Link class="work-forest-name" to={{ kind: "forest", name: proj }}>{proj}</Link>
                    <span class="work-verdict">{v.label}</span>
                    <Show when={forestOf(proj)}>
                      {(f) => <span class="work-meta">{f().branches} {f().branches === 1 ? "node" : "nodes"}</span>}
                    </Show>
                  </div>
                  <For each={list}>{(p) => workRow(p)}</For>
                </>
              );
            }}
          </For>
        </section>
      </Show>

      <Show when={tab() === "work" && landedPRs().length}>
        <section class="work-sec">
          <h2 class="eyebrow">just landed <span class="eyebrow-ask">— merged in the last day, then it fades</span></h2>
          <div class="work-rule" />
          <For each={landedPRs()}>{(p) => workRow(p)}</For>
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
          <For each={forestGroups()}>
            {(group) => (
              <>
                <Show when={multiRepo()}>
                  <h3 class="forest-repo-head">{group.repo}</h3>
                </Show>
                <For each={group.tiers}>
                  {(tier) => (
                    <>
                      <Show when={group.tiers.length > 1}>
                        <div class="forest-tier-head">
                          {tier.interest > 0 ? interestPips(tier.interest) : "no priority"}
                        </div>
                      </Show>
                      <For each={tier.items}>{(p) => forestRow(p, false)}</For>
                    </>
                  )}
                </For>
                <Show when={group.merged.length}>
                  <button class="forest-mfold" onClick={() => toggleMerged(group.repo)}>
                    {mergedOpen(group.repo) ? "▾" : "▸"} {group.merged.length} recently merged
                  </button>
                  <Show when={mergedOpen(group.repo)}>
                    <For each={group.merged}>{(p) => forestRow(p, true)}</For>
                  </Show>
                </Show>
              </>
            )}
          </For>
        </Show>
      </section>
      </Show>

      <Show when={tab() === "work" && !workCount()}>
        <p class="tab-empty">Nothing waiting on you — no open PRs or review requests.</p>
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
              <Show when={t().landed?.length}>
                <div class="forest-tip-landed">
                  <For each={t().landed}>
                    {(m) => (
                      <div class="forest-tip-landed-row" title={m.title}>
                        <span class="landed-pr">#{m.pr}</span>
                        <span class="landed-branch">{leaf(m.branch)}</span>
                        <span class="landed-ago">{mergedAgo(m.at) ?? new Date(m.at).toLocaleDateString()}</span>
                      </div>
                    )}
                  </For>
                </div>
              </Show>
            </div>
          )}
        </Show>
      </main>
      <Show when={ctxMenu()}>
        {(m) => (
          <>
            <div
              class="ctx-scrim"
              onClick={() => setCtxMenu(null)}
              onContextMenu={(e) => { e.preventDefault(); setCtxMenu(null); }}
            />
            <div class="ctx-menu" style={{ left: `${m().x}px`, top: `${m().y}px` }}>
              <div class="ctx-head">importance</div>
              <For each={[5, 4, 3, 2, 1, 0]}>
                {(lvl) => (
                  <button
                    class="ctx-item"
                    classList={{ on: m().current === lvl }}
                    onClick={() => {
                      setInterest.mutate({ repo: m().repo, project: m().project, value: lvl });
                      setCtxMenu(null);
                    }}
                  >
                    <span class="ctx-pips">{lvl === 0 ? "—" : "▲".repeat(lvl)}</span>
                    <span class="ctx-lbl">{lvl === 0 ? "none" : `level ${lvl}`}</span>
                  </button>
                )}
              </For>
            </div>
          </>
        )}
      </Show>
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
.fo-chat {
  font: inherit; font-size: 11px; cursor: pointer; padding: 3px 10px; border-radius: 6px; margin-left: 6px;
  color: var(--ember, #d2732a); background: transparent; border: 1px solid var(--gold-deep, #6e521d);
}
.fo-chat:hover { color: var(--gold-leaf, #e6b64e); border-color: var(--gold-leaf, #e6b64e); }
.fo-stage {
  font: inherit; font-size: 11px; cursor: pointer; padding: 3px 10px; border-radius: 6px; margin-left: 6px;
  color: var(--patina, #7fa093); background: transparent; border: 1px solid var(--rule, #3a332b);
}
.fo-stage:hover:not(:disabled) { color: var(--ink, #e8dcc4); border-color: var(--patina, #7fa093); }
.fo-stage:disabled { opacity: 0.5; cursor: default; }
.fo-stage.armed { color: var(--vellum-night, #14110a); background: var(--patina, #7fa093); border-color: var(--patina, #7fa093); }
.fo-stage-msg { font-size: 11px; margin-left: 6px; color: var(--ink-dim, #a89e8c); white-space: nowrap; }
.fo-stage-msg.bad { color: var(--del, #c87a55); }

/* Warming — the kiln heating before it can read the pieces (cold /forest-health, ~5s vs GitHub).
   Ember, never the blessed gold; a delay guard keeps it off sub-second warm-cache loads. */
.fo-warm { display: inline-flex; align-items: center; gap: 8px;
  font-size: 11px; letter-spacing: 0.05em; white-space: nowrap; }
.fo-warm.reading { color: var(--ember, #d2732a); }
.fo-warm.read { color: var(--ink-dim, #a89e8c); animation: fo-warm-fade 0.4s ease both; }
.fo-warm.refreshing { color: var(--ink-faint, #6f675a); }
.fo-warm b { font-weight: 500; color: var(--gold-leaf, #e6b64e); }         /* the count that earns a look */
.fo-warm .fo-coal {
  width: 7px; height: 7px; border-radius: 50%; flex: none;
  background: var(--ember, #d2732a); box-shadow: 0 0 8px var(--ember-wash, rgba(210,115,42,.12));
}
.fo-warm.reading .fo-coal { animation: fo-breathe 1.5s ease-in-out infinite; }
.fo-warm.read .fo-coal { background: var(--gold-leaf, #e6b64e); box-shadow: 0 0 8px var(--gold-wash, rgba(230,182,78,.08)); }
.fo-warm.refreshing .fo-coal { width: 5px; height: 5px; background: var(--ink-faint, #6f675a); box-shadow: none;
  animation: fo-breathe 1.9s ease-in-out infinite; }

@keyframes fo-breathe { 0%,100% { opacity: 0.35; } 50% { opacity: 1; } }
@keyframes fo-warm-fade { from { opacity: 0; transform: translateY(-2px); } to { opacity: 1; transform: none; } }
@media (prefers-reduced-motion: reduce) {
  .fo-warm .fo-coal { animation: none !important; }
  .fo-warm.reading .fo-coal { opacity: 1; }
}
@media (max-width: 600px) { .fo-warm { white-space: normal; } }
`;

// The forest header's warming indicator. Three honest states, straight from the health query —
// which maps 1:1 to the server's SWR cache: pending-with-no-data = cold read (~5s vs GitHub),
// fetching-with-data = a stale-while-revalidate background refresh, settled = read. A 400ms delay
// guard keeps it off warm-cache loads (~0.35s) so only a genuine cold read reveals it.
function WarmingRibbon(props: {
  loading: boolean;              // health query in flight
  hasData: boolean;             // some health already resolved (SWR shows it while refetching)
  needsAttention: number;       // nodes with drift/ghost — the count worth surfacing
}) {
  const [shown, setShown] = createSignal(false);   // delay-guarded: only after 400ms of a cold read
  const [justRead, setJustRead] = createSignal(false);
  let revealT: ReturnType<typeof setTimeout> | undefined;
  let readT: ReturnType<typeof setTimeout> | undefined;
  const cold = () => props.loading && !props.hasData;

  createEffect(() => {
    if (cold()) {
      clearTimeout(revealT);
      revealT = setTimeout(() => setShown(true), 400);
    } else {
      clearTimeout(revealT);
      if (shown()) {                                 // a cold read we actually surfaced just landed
        setShown(false);
        setJustRead(true);
        clearTimeout(readT);
        readT = setTimeout(() => setJustRead(false), 1600);
      }
    }
  });
  onCleanup(() => { clearTimeout(revealT); clearTimeout(readT); });

  const state = (): "reading" | "read" | "refreshing" | "" => {
    if (shown()) return "reading";
    if (justRead()) return "read";
    if (props.loading && props.hasData) return "refreshing";
    return "";
  };
  const attn = () => props.needsAttention;

  return (
    <Show when={state()}>
      {(s) => (
        <span class={`fo-warm ${s()}`} aria-live="polite">
          <span class="fo-coal" />
          <Show when={s() === "reading"}>warming · reading branch health from GitHub</Show>
          <Show when={s() === "read"}>
            <Show when={attn() > 0} fallback={<>read · all clear</>}>
              read · <b>{attn()}</b> {attn() === 1 ? "needs" : "need"} attention
            </Show>
          </Show>
          <Show when={s() === "refreshing"}>· refreshing</Show>
        </span>
      )}
    </Show>
  );
}


// "stage for testing" — restack this forest's chain forward onto fresh origin/main, then
// move the MAIN working tree onto the tip so the :3000 dev server serves the whole feature.
// Two-click armed (it moves Phil's checkout); every guard re-verified server-side, and a
// mid-chain conflict restores all branches to their pre-stage snapshots.
function StageButton(props: { project: string }) {
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [msg, setMsg] = createSignal<{ text: string; bad?: boolean } | null>(null);
  let disarm: ReturnType<typeof setTimeout>;
  const fire = async () => {
    if (!armed()) {
      setArmed(true);
      clearTimeout(disarm);
      disarm = setTimeout(() => setArmed(false), 6000);
      return;
    }
    clearTimeout(disarm);
    setArmed(false);
    setBusy(true);
    setMsg(null);
    const r = await fetch(withRepo("/stage"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ project: props.project }),
    })
      .then((x) => x.json() as Promise<{ ok?: boolean; err?: string; tip?: string; moved?: string[]; alreadyStaged?: boolean }>)
      .catch((e) => ({ ok: false, err: String(e) }));
    setBusy(false);
    if (r.ok) {
      const re = r as { tip?: string; moved?: string[]; alreadyStaged?: boolean };
      setMsg({
        text: re.alreadyStaged
          ? `✓ already staged — checkout is on ${re.tip}`
          : `✓ ${re.tip} on your checkout${re.moved?.length ? ` · ${re.moved.length} rebased` : ""}`,
      });
    } else {
      setMsg({ text: `✗ ${r.err || "stage failed"}`, bad: true });
    }
  };
  return (
    <>
      <button
        class="fo-stage"
        classList={{ armed: armed() }}
        disabled={busy()}
        title="stage for testing — restack this chain onto fresh origin/main, then move your main checkout onto the tip so the dev server serves it. Refuses on a dirty checkout, an open PR in the chain, or anything but a single main-rooted line."
        onClick={fire}
      >
        {busy() ? "staging…" : armed() ? "confirm: move my checkout" : "⇪ stage"}
      </button>
      <Show when={msg()}>
        <span class="fo-stage-msg" classList={{ bad: !!msg()!.bad }}>{msg()!.text}</span>
      </Show>
    </>
  );
}

function ForestOverview() {
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const [ovView, setOvView] = [overviewView, setOverviewView]; // shared module signal so ⌘K can open straight into a view
  const model = createQuery(() => ({
    // repo in the key so loops/monotoad forests with the same name don't share a cache entry
    // and a cross-repo nav refetches; provider reads the repo from the URL at fetch time.
    queryKey: ["model", forestRepo(location()) ?? "loops", project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  const healthIds = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", forestRepo(location()) ?? "loops", healthIds().join(",")],
    queryFn: () =>
      fetch(withRepo("/forest-health?" + healthIds().map((b) => "branch=" + encodeURIComponent(b)).join("&"))).then(
        (r) => r.json() as Promise<Record<string, { drifted: boolean; merged: boolean }>>,
      ),
    enabled: canMutate && healthIds().length > 0,
  }));
  // open PRs keyed by head branch — drives the per-node PR badge in the map. The rich /prs
  // map (base/toMain/review) is filtered to MY PRs via /myprs, so a node only badges a PR I own.
  const prs = createQuery(() => ({
    queryKey: ["branch-prs", forestRepo(location()) ?? "loops"],
    queryFn: () => provider.branchPrs(),
  }));
  const myPrs = createQuery(() => ({ queryKey: ["myprs"], queryFn: () => provider.myPrs() }));
  const myBranches = createMemo(() => new Set((myPrs.data || []).map((p) => p.branch)));
  const myBranchPrs = () => {
    const all = prs.data;
    if (!all) return undefined;
    const mine = myBranches();
    return Object.fromEntries(Object.entries(all).filter(([b]) => mine.has(b)));
  };
  // ghost endstate (✦ <project>) opens its integration diff; every other node opens itself.
  // withNode keeps the location's repo so a monotoad node stays in monotoad.
  const open = (b: string) => navigate(withNode(location(), b));
  const nodeCount = () => spine().filter((n) => !n.id.startsWith("✦")).length;
  // nodes the read turned up as needing a look — drifted off-parent or a merged ghost.
  const needsAttention = () =>
    Object.values(health.data || {}).filter((v) => v.drifted || v.merged).length;

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
        <Show when={(model.data?.interest ?? 0) > 0}>
          <span class="fo-interest" title={`interest ${model.data!.interest} — promoted on the Forests home`}>
            {interestPips(model.data!.interest!)}
          </span>
        </Show>
        <Show when={spine().length}>
          <span class="fo-meta">{nodeCount()} {nodeCount() === 1 ? "node" : "nodes"}</span>
          <WarmingRibbon loading={health.isFetching} hasData={!!health.data} needsAttention={needsAttention()} />
          <div class="fo-views" role="group" aria-label="overview view">
            <button classList={{ on: ovView() === "map" }} onClick={() => setOvView("map")} title="spatial forest map">⊞ map</button>
            <button classList={{ on: ovView() === "story" }} onClick={() => setOvView("story")} title="the feature as ordered semantic commits">≣ story</button>
          </div>
          <Show when={canMutate}>
            <button
              class="fo-chat"
              title="chat about this whole forest — what it does end to end, where the gaps are, what's left"
              onClick={() => chatToTmux({ project: project() })}
            >✦ chat</button>
            <StageButton project={project()} />
          </Show>
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
              prs={myBranchPrs}
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
  const repoKey = () => forestRepo(location()) ?? "loops"; // segregates query caches per repo
  const nodeParam = (): string | undefined => {
    const l = location();
    return l.kind === "home" || l.kind === "push" ? undefined : l.node;
  };

  const model = createQuery(() => ({
    queryKey: ["model", repoKey(), project()],
    queryFn: () => provider.model(project()),
    enabled: !!project(),
  }));
  const spine = createMemo(() => flattenForest(model.data));
  // default to the first node with actual files — a fan-in forest's first root is often an empty
  // integrator (total 0), so landing there shows a blank surface; skip to one with something to review.
  const active = () =>
    nodeParam() || spine().find((n) => (n.total ?? 0) > 0)?.id || spine()[0]?.id || project();
  const parentOf = () => model.data?.nodes?.[active()]?.parent;
  const interestOf = () => model.data?.interest ?? 0;
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
  // "@origin" = the OUTGOING view: exactly what the red button would send (origin/<branch>…branch).
  // Resolved here because the sentinel must survive branch navigation; stack-forest takes the
  // resolved ref verbatim.
  const nodeBase = () => (isGhost() ? "main" : base() === "@origin" ? `origin/${active()}` : base() || undefined);
  const nodeKey = () => ["node", repoKey(), nodeRef(), nodeBase() ?? ""];

  // ⇧B/⇧U flip a file's blessed state through this local override, NOT the query cache. Writing
  // status into the cache replaces the FileDiff object, so <For> tears the row down and re-mounts
  // it — on unbless that re-renders the whole diff from scratch, which read as a refetch flash.
  // path → blessed?; keeps the object identity stable so the row just expands/collapses in place.
  // Cleared when the node changes (the next load carries fresh server truth). isBlessed reconciles.
  const [blessOverride, setBlessOverride] = createSignal<Record<string, boolean>>({});
  const blessedOf = (f: FileDiff): boolean => {
    const o = blessOverride()[f.path];
    return o === undefined ? isBlessed(f) : o;
  };
  const setOverride = (file: string, val: boolean | undefined) =>
    setBlessOverride((m) => {
      const n = { ...m };
      if (val === undefined) { delete n[file]; } else { n[file] = val; }
      return n;
    });
  createEffect(on(() => nodeKey().join("|"), () => setBlessOverride({}), { defer: true }));

  const node = createQuery(() => ({
    queryKey: nodeKey(),
    queryFn: () => provider.node(nodeRef(), nodeBase()),
    enabled: !!active(),
  }));
  const commits = createQuery(() => ({
    queryKey: ["commits", repoKey(), active()],
    queryFn: () => provider.commits(active()),
    enabled: !!active() && view() === "commits",
  }));

  // Optimistic in the override, no cache write and no refetch on the keystroke — the row flips in
  // place. onError restores the prior override so a failed POST snaps back.
  const bless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch(withRepo("/bless"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file }),
      }).then((r) => r.json()),
    onMutate: (file: string) => { const prev = blessOverride()[file]; setOverride(file, true); return { file, prev }; },
    onError: (_e, _file, ctx) => { if (ctx) { setOverride(ctx.file, ctx.prev); } },
  }));

  const unbless = createMutation(() => ({
    mutationFn: (file: string) =>
      fetch(withRepo("/bless"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: active(), file, unbless: true }),
      }).then((r) => r.json()),
    onMutate: (file: string) => { const prev = blessOverride()[file]; setOverride(file, false); return { file, prev }; },
    onError: (_e, _file, ctx) => { if (ctx) { setOverride(ctx.file, ctx.prev); } },
  }));

  // promote/demote this forest's manual interest level — orders it on the Forests home.
  const bumpInterest = createMutation(() => ({
    mutationFn: (arg: { project: string; delta: number }) =>
      fetch(withRepo("/interest"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(arg),
      }).then((r) => r.json()),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["projects"] });
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

  // scoped reseat for a drifted node: rebase the parent's off-tip children (this node and any
  // orphaned siblings, recursively) back onto the parent's current tip — nothing else moves,
  // unlike a full restack. Local only; conflicts leave that subtree parked for a manual pass.
  const reseatChildren = createMutation(() => ({
    mutationFn: (parent: string) =>
      fetch("/reseat-children", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: parent }),
      }).then((r) => r.json() as Promise<{ ok: boolean; moved: string[]; conflicts: { branch: string; err: string }[] }>),
    onSuccess: () => {
      health.refetch();
      qc.invalidateQueries({ queryKey: ["model"] }); // children's SHAs moved — diffs are stale
    },
  }));

  const goto = (b: string) => navigate(withNode(location(), b));
  const BASES: [string, string][] = [["", "parent"], ["main", "main"], ["blessed", "last blessed"], ["@origin", "outgoing"]];
  // The forest map is a destination (the /forests/<project> overview), never docked into
  // the review surface — the diff gets the full width. "back to the forest map" lives in the
  // node header (nh-forest-back).

  // ── forest health: per-node drifted (off-parent → its diff balloons to ≈main) / merged-ghost,
  // for badges + a one-click "fix forest" (restack). Live-only; refetch after a fix lands.
  const healthIds = createMemo(() => spine().map((n) => n.id).filter(Boolean));
  const health = createQuery(() => ({
    queryKey: ["forest-health", forestRepo(location()) ?? "loops", healthIds().join(",")],
    queryFn: () =>
      fetch(withRepo("/forest-health?" + healthIds().map((b) => "branch=" + encodeURIComponent(b)).join("&"))).then(
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
  // the ambient daemon's per-branch dry-run verdict (shared cache with Home's chip) — surfaces
  // "would restack" / "conflicts with #PR" on the node you're actually looking at.
  const ambient = createQuery(() => ({
    queryKey: ["restack-ambient"],
    queryFn: () => provider.restackAmbient(),
    refetchInterval: 15000,
  }));
  const nodeAmbient = (b: string) => ambient.data?.report?.branches.find((x) => x.branch === b);

  // the ⇄ diverged chip's inspect panel: what the divergence actually IS, in the PR's frame —
  // each side's commits with patch-id twins flagged (a rebase reads as "same change, rewritten"),
  // a containment verdict, and what origin's review diff shows today vs after pushing local.
  // Tip-to-tip diffs are deliberately absent: post-restack they're all main-advance noise.
  const [divergedOpen, setDivergedOpen] = createSignal(false);
  createEffect(on(active, () => setDivergedOpen(false)));
  // a dirt verdict's receipt — outlives the rail, which unmounts the moment the tree goes
  // clean (success must not read as disappearance).
  const [dirtReceipt, setDirtReceipt] = createSignal<string | null>(null);
  let dirtReceiptT: ReturnType<typeof setTimeout>;
  const divergedDetail = createQuery(() => ({
    queryKey: ["diverged-detail", forestRepo(location()) ?? "loops", active()],
    queryFn: () =>
      fetch(withRepo("/diverged-detail?branch=" + encodeURIComponent(active()))).then(
        (r) =>
          r.json() as Promise<{
            ok: boolean;
            err?: string;
            upstream?: string;
            trunk?: string;
            ahead?: { sha: string; subject: string; matched: boolean; fromMain: boolean }[];
            behind?: { sha: string; subject: string; matched: boolean }[];
            containment?: "rebase" | "contained" | "clean-extra" | "overlap";
            overlap?: string[];
            prNow?: string;
            prAfter?: string;
            prFiles?: { path: string; status: "same" | "changed" | "enters" | "leaves"; now: string | null; after: string | null }[];
          }>,
      ),
    enabled: divergedOpen() && !!nodeHealth(active())?.diverged,
  }));

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

  // hover a diff line + press o → open that exact line in the warm review-nvim. Hover-armed and
  // event-delegated off the surface; there is deliberately no click-to-open — a mouse click on a
  // line collided with plain text selection, so opening is keyboard-only.
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
    else if (e.key === "4") setBase("@origin");
    else if (e.key === "o" && hover()) { e.preventDefault(); const h = hover()!; openInNvim(h.path, h.line); }
    else if (e.key === "c") setView((v) => (v === "commits" ? "diffs" : "commits"));
    else if (e.key === "b") { e.preventDefault(); filterAutoOpenedPanel = false; setPanelOpen((v) => !v); } // show / hide the file panel
    // ⇧B blesses the focused file and advances (B·B·B down a branch, no mouse); ⇧U unblesses it in
    // place. Per-file only — there is deliberately no bless-all key.
    // advance in the next frame — after the just-blessed card collapses — so the scroll lands the
    // next card at the toolbar line instead of over-shooting past the freed-up space.
    else if (e.key === "B" && activeFile()) { e.preventDefault(); bless.mutate(activeFile()); requestAnimationFrame(() => fileCycle.next()); }
    else if (e.key === "U" && activeFile()) { e.preventDefault(); unbless.mutate(activeFile()); }
    else if (e.key === "?") { e.preventDefault(); setShowHelp((v) => !v); }
    else if (e.key === "m") {
      // m → up to the forest view. The key reached for by muscle memory (Esc does it too).
      e.preventDefault();
      const p = project();
      if (p) navigate({ kind: "forest", name: p, repo: forestRepo(location()) });
    }
    else if (e.key === "Escape") {
      // up a level: help → close it; else (when the chat drawer isn't grabbing Esc) → the forest map
      if (showHelp()) { setShowHelp(false); }
      else if (!chatTarget()) { const p = project(); if (p) { navigate({ kind: "forest", name: p, repo: forestRepo(location()) }); } }
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
  const matchFilter = (f: { path: string }): boolean => {
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
                    : `${data().files.filter(blessedOf).length}/${data().files.length} files blessed`}
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
                          classList={{ blessed: blessedOf(f), active: activeFile() === f.path }}
                          onClick={() => scrollToFile(f.path)}
                          title={f.path}
                        >
                          <span class={`dot ${blessedOf(f) ? "blessed" : "unblessed"}`} />
                          <span class="file-item-name">{fileSeg(f.path)}</span>
                          <span class="file-item-lines">
                            <span class="add">+{f.add ?? 0}</span>
                            <span class="del">−{f.del ?? 0}</span>
                          </span>
                        </li>
                      )}
                    </For>
                  </ul>
                  <Show when={(data().dirty?.length ?? 0) > 0}>
                    {/* dirt files are DRIVABLE rows, same as the review set — click jumps to the
                        card, tab already cycles through them (.entry[data-path]). The story lives
                        in the divider's tooltip; the rows do the work. */}
                    <div
                      class="file-list-dirt-head"
                      title={`uncommitted changes riding ${data().worktree || "the checkout"} — not part of this review, never blessed; ⟲ sync stops to ask about them`}
                    >
                      ± uncommitted · {(data().worktree ?? "").replace(/.*\//, "") || "checkout"}
                    </div>
                    <ul class="file-list">
                      <For each={data().dirty!.filter((f) => matchFilter(f))}>
                        {(f) => (
                          <li
                            class="file-item dirt"
                            classList={{ active: activeFile() === f.path }}
                            onClick={() => scrollToFile(f.path)}
                            title={f.path}
                          >
                            <span class="dot dirt" />
                            <span class="file-item-name">{fileSeg(f.path)}</span>
                          </li>
                        )}
                      </For>
                    </ul>
                  </Show>
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
                to={{ kind: "forest", name: project(), repo: forestRepo(location()) }}
                title="back to the forest map — your current node stays highlighted there"
              >
                ⊞ {project()}
              </Link>
            </Show>
            <div class="nh-spacer" />
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
            <Show when={!isGhost() && interestOf() > 0}>
              <span class="nh-ready" title={`interest ${interestOf()} — this forest is promoted on the Forests home`}>
                {interestPips(interestOf())}
              </span>
            </Show>
            {/* health badges folded into the spine (reasons tooltip + ⋯ overrides) — what
                remains here is only the transient outcome of a repair fired from ⋯. */}
            <Show when={reseatChildren.isPending || detachUpstream.isPending}>
              <span class="nh-drift">{reseatChildren.isPending ? "⤴ reseating…" : "✂ detaching…"}</span>
            </Show>
            <Show when={reseatChildren.data && !reseatChildren.data.ok}>
              <span
                class="nh-drift"
                title={reseatChildren.data!.conflicts.map((c) => `${c.branch}: ${c.err}`).join("\n")}
              >
                ⚠ reseat: {reseatChildren.data!.conflicts.length} conflicted — resolve by hand or restack
              </span>
            </Show>
          </div>
          <Show when={divergedOpen() && nodeHealth(active())?.diverged}>
            <div
              class="nh-diverged-detail"
              style={{
                margin: "6px 0 2px",
                padding: "10px 12px",
                border: "1px solid var(--line, #444)",
                "border-radius": "8px",
                "font-size": "12.5px",
                "line-height": "1.55",
              }}
            >
              <Show when={divergedDetail.data} fallback={<span>reading both sides…</span>}>
                <Show when={divergedDetail.data!.ok} fallback={<span>✗ {divergedDetail.data!.err}</span>}>
                  <div style={{ "margin-bottom": "6px" }}>
                    <Switch>
                      <Match when={divergedDetail.data!.containment === "rebase"}>
                        <span>
                          only a local rebase — every pushed-head commit is patch-identical to a local one, so the PR's
                          content already matches. Nothing to push; leave origin alone.
                        </span>
                      </Match>
                      <Match when={divergedDetail.data!.containment === "contained"}>
                        <span>
                          local already contains everything the pushed head has (a squash/rework absorbed it). If the PR
                          diff below changed, update it ADDITIVELY — a commit on top of the pushed head; an open PR's
                          history is shared, never force-push it.
                        </span>
                      </Match>
                      <Match when={divergedDetail.data!.containment === "clean-extra"}>
                        <span>
                          ⚠ the pushed head has work local lacks (it would merge cleanly) — bring it into local first
                          (reconcile), then update the PR additively if anything remains.
                        </span>
                      </Match>
                      <Match when={divergedDetail.data!.containment === "overlap"}>
                        <span>
                          local reworked what the pushed head has ({(divergedDetail.data!.overlap ?? []).join(", ")}) —
                          update the PR ADDITIVELY: one commit on top of the pushed head carrying the rework (reconcile
                          drafts exactly that; an open PR's history is shared, never force-push it).
                        </span>
                      </Match>
                    </Switch>
                    <div style={{ opacity: 0.75 }}>
                      PR diff on origin today: {divergedDetail.data!.prNow || "empty"} → after carrying local's content:{" "}
                      {divergedDetail.data!.prAfter || "empty"}
                    </div>
                  </div>
                  <div style={{ display: "flex", gap: "24px", "flex-wrap": "wrap" }}>
                    <div>
                      <div style={{ opacity: 0.65 }}>only local ({(divergedDetail.data!.ahead ?? []).length}↑)</div>
                      <For each={divergedDetail.data!.ahead}>
                        {(c) => (
                          <div>
                            <code>{c.sha}</code> {c.subject}{" "}
                            <span style={{ opacity: 0.6 }}>
                              {c.matched ? "≡ rewritten twin" : c.fromMain ? "↳ main advance (restack)" : "◆ new work"}
                            </span>
                          </div>
                        )}
                      </For>
                    </div>
                    <div>
                      <div style={{ opacity: 0.65 }}>only pushed head ({(divergedDetail.data!.behind ?? []).length}↓)</div>
                      <For each={divergedDetail.data!.behind}>
                        {(c) => (
                          <div>
                            <code>{c.sha}</code> {c.subject}{" "}
                            <span style={{ opacity: 0.6 }}>{c.matched ? "≡ rewritten twin" : "◆ no local twin"}</span>
                          </div>
                        )}
                      </For>
                    </div>
                    <Show when={(divergedDetail.data!.prFiles ?? []).length > 0}>
                      <div>
                        <div style={{ opacity: 0.65 }}>
                          the PR's diff, file by file (now → after an additive update)
                        </div>
                        <For each={divergedDetail.data!.prFiles}>
                          {(f) => (
                            <div>
                              <code>{f.path}</code>{" "}
                              <span style={{ opacity: 0.6 }}>
                                <Switch>
                                  <Match when={f.status === "same"}>{f.now} · unchanged</Match>
                                  <Match when={f.status === "changed"}>
                                    {f.now} → {f.after}
                                  </Match>
                                  <Match when={f.status === "enters"}>＋ enters the PR ({f.after})</Match>
                                  <Match when={f.status === "leaves"}>－ leaves the PR (was {f.now})</Match>
                                </Switch>
                              </span>
                            </div>
                          )}
                        </For>
                      </div>
                    </Show>
                  </div>
                </Show>
              </Show>
            </div>
          </Show>
          {/* tier 2 — controls: view switches on the left, branch state + actions on the right.
              The blessed count lives in the spine; the map opens from the spine + `m`. */}
          {/* tier-2 (Phil, strikes 6+7): no view controls at all — c flips diffs⇄commits,
              1/2/3 set the diff base, both taught in ? help. The base shows as passive text
              only when it's not the default, so a non-parent diff can't masquerade. */}
          <div class="nh-bar">
            <Show when={view() === "commits"}>
              <span class="nh-viewnote">commits · c for diffs</span>
            </Show>
            <Show when={view() === "diffs" && base() !== "" && !isGhost()}>
              <span class="nh-viewnote">vs {(BASES.find(([v]) => v === base()) ?? BASES[0])[1]} · 1 for parent</span>
            </Show>
            <div class="nh-spacer" />
            <Show when={!isGhost()}>
              <NodeActions
                branch={active()}
                isReview={location().kind === "review"}
                merged={nodeHealth(active())?.merged}
                ambient={nodeAmbient(active())}
                blessing={node.data ? { total: node.data.files.length, blessed: node.data.files.filter(blessedOf).length } : undefined}
                health={nodeHealth(active())}
                onReseat={() => { const p = nodeHealth(active())?.parent; if (p) reseatChildren.mutate(p); }}
                onDetach={() => detachUpstream.mutate(active())}
                onInspect={() => setDivergedOpen(!divergedOpen())}
                interest={canMutate ? interestOf() : undefined}
                onBump={canMutate ? (delta) => bumpInterest.mutate({ project: project(), delta }) : undefined}
                onAllChats={() => setShowChats(true)}
              />
            </Show>
            <Show when={canMutate}>
              <button class="icon-btn" onClick={() => chatToTmux({ branch: active() })} title="chat about this whole branch — opens an interactive claude beside your tmux panes">
                ✦
              </button>
            </Show>
          </div>
        </header>
        <Show when={view() === "diffs"} fallback={<CommitsList q={commits} />}>
          <div class="diff-hint">
            <span class="kbd-hint"><b>tab</b> next file · <b>b</b> files · <b>⌘F</b> filter · <b>?</b> shortcuts</span>
          </div>
          <Show when={node.data} fallback={<p class="loading">loading…</p>}>
            {(data) => (
              <Show
                when={data().files.length}
                fallback={
                  <p class="loading">
                    {base() === "@origin"
                      ? "nothing outgoing — origin already has all of this (or the branch was never pushed; vs parent shows everything)"
                      : "nothing to review here ✦"}
                  </p>
                }
              >
                <Show when={data().files.filter(matchFilter).length} fallback={<p class="loading">no files match “{fileFilter()}”</p>}>
                  <For each={data().files.filter(matchFilter)}>
                    {(f) => <FileEntry file={f} blessed={() => blessedOf(f)} bless={bless} branch={active()} readOnly={isGhost()} onChat={(file) => chatToTmux({ branch: active(), path: file.path, patch: file.patch })} />}
                  </For>
                </Show>
              </Show>
            )}
          </Show>
          {/* uncommitted — working-tree dirt of the worktree holding this branch. Read-only:
              blessing keys on committed content, and dirt isn't committed anywhere yet. This
              is the local-vs-shared model's missing tier made visible (the dirty-sync incident:
              dirt was only ever discovered by tripping a guard). */}
          <Show when={(node.data?.dirty?.length ?? 0) > 0}>
            <DirtyRail
              dirty={node.data!.dirty!}
              worktree={node.data!.worktree ?? ""}
              branch={active()}
              bless={bless}
              onCommit={(receipt) => {
                node.refetch();
                if (receipt) {
                  setDirtReceipt(receipt);
                  clearTimeout(dirtReceiptT);
                  dirtReceiptT = setTimeout(() => setDirtReceipt(null), 8000);
                }
              }}
              onChat={(file) => chatToTmux({ branch: active(), path: file.path, patch: file.patch })}
            />
          </Show>
          <Show when={dirtReceipt()}>
            <p class="dirt-receipt">{dirtReceipt()}{(node.data?.dirty?.length ?? 0) === 0 ? " · working tree clean" : ""}</p>
          </Show>
        </Show>
      </main>
      <Show when={showChats()}>
        <ChatIndex onClose={() => setShowChats(false)} onOpen={openChatInContext} />
      </Show>
      <Show when={showHelp()}>
        <div class="kbd-help-scrim" onClick={() => setShowHelp(false)}>
          <div class="kbd-help" onClick={(e) => e.stopPropagation()}>
            <div class="kbd-help-head">keyboard · reviewing a branch</div>
            <dl>
              <div><dt><span class="k">tab</span></dt><dd>next file</dd></div>
              <div><dt><span class="k">c</span></dt><dd>flip diffs ⇄ commits</dd></div>
              <div><dt><span class="k">1</span><span class="k">2</span><span class="k">3</span><span class="k">4</span></dt><dd>diff vs parent / main / last blessed / outgoing (what a push sends)</dd></div>
              <div><dt><span class="k">b</span></dt><dd>show / hide the file panel</dd></div>
              <div><dt><span class="k">⌘F</span></dt><dd>filter files</dd></div>
              <div><dt><span class="k">⇧B</span></dt><dd>bless file &amp; advance</dd></div>
              <div><dt><span class="k">⇧U</span></dt><dd>unbless file</dd></div>
              <div><dt><span class="k">o</span></dt><dd>open hovered line in nvim</dd></div>
              <div><dt><span class="k">m</span><span class="k">esc</span></dt><dd>up to the forest</dd></div>
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

function patchLineCounts(patch: string): { add: number; del: number } {
  let add = 0, del = 0;
  for (const line of patch.split("\n")) {
    if (line.startsWith("+") && !line.startsWith("+++")) add++;
    else if (line.startsWith("-") && !line.startsWith("---")) del++;
  }
  return { add, del };
}

function DirtyRail(props: {
  dirty: { path: string; code: string; patch: string }[];
  worktree: string;
  branch: string;
  bless: { mutate: (file: string) => void };
  onCommit: (receipt?: string) => void;
  onChat: (f: FileDiff) => void;
}) {
  const [msg, setMsg] = createSignal("");
  const [err, setErr] = createSignal("");
  const [busy, setBusy] = createSignal(false);
  const [showForm, setShowForm] = createSignal(false);
  let inputEl: HTMLInputElement | undefined;

  const submit = async () => {
    if (!msg().trim()) return;
    setBusy(true);
    setErr("");
    try {
      const r = await fetch(withRepo("/commit-dirty"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch: props.branch, message: msg().trim() }),
      });
      const j = await r.json();
      if (!j.ok) { setErr(j.err ?? "commit failed"); return; }
      setMsg("");
      setShowForm(false);
      props.onCommit("✓ all uncommitted changes committed to the branch");
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="uncommitted-rail">
      <div class="ur-head">
        <span class="ur-label">± uncommitted — working tree only</span>
        <span class="ur-wt">{props.worktree.replace(/.*\//, "")}</span>
        <button
          class="ur-commit-btn"
          title="commit all uncommitted changes to this branch"
          onClick={() => { setShowForm((v) => !v); setTimeout(() => inputEl?.focus(), 0); }}
        >
          {showForm() ? "✕" : "↓ commit"}
        </button>
      </div>
      <Show when={showForm()}>
        <div class="ur-commit-form">
          <input
            ref={inputEl}
            class="ur-commit-input"
            placeholder="commit message…"
            value={msg()}
            onInput={(e) => setMsg(e.currentTarget.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } }}
            disabled={busy()}
          />
          <button class="ur-commit-go" onClick={submit} disabled={busy() || !msg().trim()}>
            {busy() ? "…" : "commit"}
          </button>
        </div>
        <Show when={err()}>
          <div class="ur-commit-err">{err()}</div>
        </Show>
      </Show>
      <For each={props.dirty}>
        {(f) => <DirtFile f={f} branch={props.branch} bless={props.bless} onChat={props.onChat} onDone={props.onCommit} />}
      </For>
    </div>
  );
}

// One dirty file with its verdict: accept (commit just this file, message inline) or
// reject (tracked → restore to HEAD, untracked → delete; armed — it destroys work).
function DirtFile(props: {
  f: { path: string; code: string; patch: string };
  branch: string;
  bless: { mutate: (file: string) => void };
  onChat: (f: FileDiff) => void;
  onDone: (receipt?: string) => void;
}) {
  const [form, setForm] = createSignal(false);
  const [msg, setMsg] = createSignal("");
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [err, setErr] = createSignal("");
  let disarm: ReturnType<typeof setTimeout>;
  let inputEl: HTMLInputElement | undefined;
  const post = async (url: string, body: unknown) => {
    setBusy(true);
    setErr("");
    try {
      const r = await fetch(withRepo(url), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const j = await r.json();
      if (!j.ok) {
        setErr(j.err ?? "failed");
        return;
      }
      const name = props.f.path.replace(/.*\//, "");
      props.onDone(
        url === "/discard-dirty"
          ? `✕ ${name} ${j.was === "tracked" ? "restored to HEAD" : "deleted"} — the uncommitted change is gone`
          : `✓ ${name} committed to the branch`,
      );
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };
  const reject = () => {
    if (!armed()) {
      setArmed(true);
      clearTimeout(disarm);
      disarm = setTimeout(() => setArmed(false), 5000);
      return;
    }
    clearTimeout(disarm);
    setArmed(false);
    post("/discard-dirty", { branch: props.branch, path: props.f.path });
  };
  return (
    <div class="ur-file">
      <div class="ur-file-acts">
        <Show
          when={!form()}
          fallback={
            <>
              <input
                ref={inputEl}
                class="ur-commit-input"
                placeholder={`message for ${props.f.path.replace(/.*\//, "")}…`}
                value={msg()}
                onInput={(e) => setMsg(e.currentTarget.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && msg().trim()) {
                    e.preventDefault();
                    post("/commit-dirty", { branch: props.branch, message: msg().trim(), path: props.f.path });
                  }
                  if (e.key === "Escape") { e.stopPropagation(); setForm(false); }
                }}
                disabled={busy()}
              />
              <button
                class="ur-commit-go"
                disabled={busy() || !msg().trim()}
                onClick={() => post("/commit-dirty", { branch: props.branch, message: msg().trim(), path: props.f.path })}
              >
                {busy() ? "…" : "commit"}
              </button>
              <button class="ur-file-x" onClick={() => setForm(false)}>✕</button>
            </>
          }
        >
          <button
            class="ur-file-accept"
            disabled={busy()}
            title="accept — commit just this file to the branch (message next)"
            onClick={() => { setForm(true); setTimeout(() => inputEl?.focus(), 0); }}
          >
            ✓ accept
          </button>
          <button
            class="ur-file-reject"
            classList={{ armed: armed() }}
            disabled={busy()}
            title="reject — a tracked file restores to HEAD, an untracked one is deleted. This destroys the uncommitted work; two clicks."
            onClick={reject}
          >
            {busy() ? "…" : armed() ? "confirm: discard" : "✕ reject"}
          </button>
        </Show>
        <Show when={err()}>
          <span class="ur-commit-err">{err()}</span>
        </Show>
      </div>
      <FileEntry
        file={{ path: props.f.path, status: "dirty", patch: props.f.patch, ...patchLineCounts(props.f.patch) }}
        bless={props.bless}
        branch={props.branch}
        readOnly
        onChat={props.onChat}
      />
    </div>
  );
}

function FileEntry(props: {
  file: FileDiff;
  blessed?: () => boolean;
  bless: { mutate: (file: string) => void };
  branch: string;
  readOnly?: boolean;
  onChat: (f: FileDiff) => void;
}) {
  const [foil, setFoil] = createSignal(false);
  const [copied, setCopied] = createSignal(false);
  // memo (not a bare accessor) so it only notifies on a real value change — a ⇧B on some *other*
  // row bumps the shared override signal but leaves this one's value alone, so the follow effect
  // below must not fire (it would clobber a manual expand/collapse).
  const blessed = createMemo(() => (props.blessed ? props.blessed() : isBlessed(props.file)));
  // a blessed file starts collapsed — it's reviewed with nothing new since (a changed-since-
  // blessed file reads as 'stale', not blessed), so it shouldn't cost screen space. Stale and
  // unblessed files start open.
  const [collapsed, setCollapsed] = createSignal(blessed());
  // follow bless state in place: ⇧B collapses this card, ⇧U expands it — no row teardown, so the
  // diff isn't re-rendered from scratch (defer skips the initial value, keeping manual toggles).
  createEffect(on(blessed, (b) => setCollapsed(b), { defer: true }));
  const chatWorking = () => threadWorking(props.branch, props.file.path);
  const chatUnseen = () => threadUnseenDone(props.branch, props.file.path);
  const doBless = () => {
    setFoil(true); // play the foil on the click; the steady gold lands as the override flips
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
  // a stale file (blessed once, changed since) can flip between its FULL diff and just the
  // delta past the blessed state — the part that's actually unreviewed.
  const tarnished = () => props.file.status === "stale" && !blessed();
  const [deltaView, setDeltaView] = createSignal(false);
  const shownPatch = () => (deltaView() && props.file.stale ? props.file.stale : props.file.patch);
  const html = () =>
    shownPatch()
      ? Diff2Html.html(shownPatch()!, {
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
        <span class="gutter" classList={{ tarnish: tarnished() }}>{blessed() || foil() || tarnished() ? "✦" : ""}</span>
        <span class="path" onClick={() => setCollapsed((c) => !c)}>{seg(props.file.path)}</span>
        <span class="lines">
          <span class="add">+{props.file.add ?? 0}</span>
          <span class="del">−{props.file.del ?? 0}</span>
        </span>
        <Show when={tarnished() && props.file.stale}>
          <button
            class="file-act tarnish-chip"
            classList={{ on: deltaView() }}
            title="blessed once, changed since — flip between the full diff and just the delta past the blessed state (the unreviewed part)"
            onClick={() => { setDeltaView((v) => !v); setCollapsed(false); }}
          >
            {deltaView() ? "Δ vs blessed" : "✦ tarnished"}
          </button>
        </Show>
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
