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
import { provider, canMutate, withRepo } from "./provider";
import { deleteMode, setDeleteMode } from "./deleteMode";
import { ForestMap } from "./ForestMap";
import MergeStory from "./MergeStory";
import { overviewView, setOverviewView } from "./overviewView";
import ChatPanel from "./ChatPanel";
import { chatTarget, closeChat, chatToTmux } from "./chatDrawer";
import { reconcile as reconcileChats } from "./chatRunner";
import CommandPalette from "./CommandPalette";
import { track, installFetchTracking, installUiTracking } from "./track";
import { ServerStatus } from "./ServerStatus";
import { Hearth } from "./Hearth";
import { Activity } from "./Activity";
import MobilePush from "./MobilePush";
import { leaf, mergedAgo, interestPips, flattenForest } from "./shared";
import { cameFrom } from "./cameFrom";
import { NodeDetail } from "./NodeDetail";
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
  // shared cache with the Cmd+K index — lets the ambient chip resolve which forest its
  // actionable branches live in, so a click routes straight to that forest's ▸ ready button.
  const forestBranches = createQuery(() => ({
    queryKey: ["forest-branches"],
    queryFn: () => provider.forestBranches(),
    refetchInterval: 60000,
  }));
  // collapse the summary to the single most-urgent signal: a real conflict outranks an
  // already-merged ghost outranks pending restacks; all-zero behind = the forest is clean.
  const ambientChip = (): { cls: string; text: string; title: string; to?: ViewerLocation } | null => {
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
    // in an auto-drop tier the daemon already deletes merged ghosts, so anything still showing
    // is HELD (checked out in a worktree); in dry-run nothing is being dropped, so it's a to-do.
    const autoDrops = a.tier === "contract" || a.tier === "apply";
    const ghosts = a.report.branches.filter((b) => b.verdict === "would-contract");
    if (ghosts.length) {
      title += autoDrops
        ? "\n\nalready merged — the --contract daemon auto-drops these; any still here are held"
          + " (checked out in a worktree). Check out elsewhere, or a forest's ▸ ready button clears them:\n"
          + ghosts.map((b) => `  ${b.branch}`).join("\n")
        : "\n\nalready merged — the daemon isn't auto-dropping (dry-run); a forest's ▸ ready button drops"
          + " these, or reinstall it with `restack-daemon --contract install`:\n"
          + ghosts.map((b) => `  ${b.branch}`).join("\n");
    }
    // route a click to the forest carrying the most actionable branches (or Work when they
    // span several) — the chip surfaces the drift, the forest's ▸ ready button stages the fix.
    const projectOf = (branch: string) => (forestBranches.data || []).find((fb) => fb.branch === branch)?.project;
    const counts = new Map<string, number>();
    for (const b of a.report.branches) {
      if (b.verdict !== "will-conflict" && b.verdict !== "would-restack" && b.verdict !== "would-contract") continue;
      const p = projectOf(b.branch);
      if (p) counts.set(p, (counts.get(p) ?? 0) + 1);
    }
    const to: ViewerLocation | undefined = counts.size === 1
      ? { kind: "forest", name: [...counts.keys()][0] }
      : counts.size > 1 ? { kind: "home", tab: "work" } : undefined;
    if (stale) return { cls: "amb-stale", text: "✦ daemon idle", title };
    if (s.will_conflict > 0) return { cls: "amb-conflict", text: `⚠ ${s.will_conflict} will conflict`, title, to };
    if (s.would_contract > 0) {
      const text = autoDrops ? `⊘ ${s.would_contract} merged — held` : `⊘ ${s.would_contract} merged — drop?`;
      return { cls: "amb-contract", text, title, to };
    }
    if (s.would_restack > 0) return { cls: "amb-restack", text: `⟳ ${s.would_restack} would restack`, title, to };
    return { cls: "amb-clean", text: "✦ forest clean", title };
  };

  // what just landed on main (the daemon's merge attribution) → a second quiet chip.
  // Gold + PR numbers when any of it is YOURS; a dim count otherwise; gone after a day.
  const merges = createQuery(() => ({
    queryKey: ["restack-merges"],
    queryFn: () => provider.restackMerges(),
    refetchInterval: 15000,
  }));
  const landedChip = (): { cls: string; text: string; title: string; to?: ViewerLocation } | null => {
    const m = merges.data;
    if (!m?.available || !m.prs?.length) return null;
    if ((m.age_s ?? Infinity) > 24 * 3600) return null; // yesterday's news isn't "just" landed
    const age = m.age_s == null ? "" : m.age_s < 90 ? "just now"
      : m.age_s < 3600 ? `${Math.round(m.age_s / 60)}m ago` : `${Math.round(m.age_s / 3600)}h ago`;
    const mine = m.prs.filter((p) => p.mine === true);
    const nums = mine.map((p) => `#${p.number}`).join(" ");
    const title = m.prs
      .map((p) => `#${p.number} ${p.title ?? ""}${p.mine ? " — yours" : p.author ? ` — ${p.author}` : ""}`)
      .join("\n") + (m.direct ? `\n+ ${m.direct} direct push(es)` : "") + `\n\nlanded ${age}`;
    if (mine.length) {
      // the daemon's --apply pass has already contracted these merged branches and restacked +
      // prepped the survivors, so the chip's job shifts from "what landed" to "what's next": each
      // landed PR maps to its forest via the merge fact, and that forest's first mergeable base is
      // the just-prepped next-to-push — link straight to it.
      const nextForest = mine
        .map((p) => (projects.data || []).find((f) => f.merged && (f.merged.pr === p.number || f.merged.branch === p.branch)))
        .find((f) => f?.candidates?.length);
      const base = nextForest?.candidates?.[0];
      if (base && nextForest) {
        return {
          cls: "landed-mine",
          text: `⛳ ${nums} landed — next ▸ ${leaf(base)}`,
          title: `${title}\n\nadvanced: forest restacked onto fresh main; next base ${base} prepped for push`,
          to: { kind: "forest", name: nextForest.name, node: base },
        };
      }
      return { cls: "landed-mine", text: `⛳ ${nums} landed — yours`, title };
    }
    return { cls: "landed-other", text: `⛳ ${m.prs.length} landed ${age}`, title };
  };

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
  // A landed row's answer to "what now": the forest's first mergeable root still
  // without a PR — the natural next push after a merge contracts the stack.
  const nextUp = (p: PR): string | undefined =>
    p.project ? forestOf(p.project)?.candidates?.[0] : undefined;

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
        <Show when={state === "landed" && nextUp(p)}>
          {(n) => (
            <Link class="work-next" to={{ kind: "forest", name: p.project!, node: n() }}>
              next ▸ {leaf(n())}
            </Link>
          )}
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
  // A project's identity is (repo, name) — the same forest name can exist in two repos.
  const pkey = (p: Project) => (p.repo || "loops") + " " + p.name;
  // Cross-repo "epic" clusters: same stack-project.<name>.epic tag spanning ≥2 repos folds into one
  // card at the top (ranked by its members' max interest). A single-repo epic is left in its normal
  // repo bucket — pulling one row out into a lone "cluster" would only fragment the list.
  const epicClusters = createMemo(() => {
    const byEpic = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (!p.epic || recentlyMerged(p)) continue;
      (byEpic.get(p.epic) ?? byEpic.set(p.epic, []).get(p.epic)!).push(p);
    }
    return [...byEpic.entries()]
      .filter(([, items]) => new Set(items.map((p) => p.repo || "loops")).size >= 2)
      .map(([epic, items]) => ({
        epic,
        interest: Math.max(...items.map((p) => p.interest ?? 0)),
        items: items.sort((a, b) => forestTs(b) - forestTs(a)),
      }))
      .sort((a, b) => b.interest - a.interest || b.items.length - a.items.length);
  });
  const clusteredKeys = createMemo(() => new Set(epicClusters().flatMap((c) => c.items.map(pkey))));
  const forestGroups = createMemo(() => {
    const clustered = clusteredKeys();
    const by = new Map<string, Project[]>();
    for (const p of filteredForests()) {
      if (clustered.has(pkey(p))) continue; // shown in an epic cluster above, not under its repo header
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
          <Show when={landedChip()}>
            {(c) => c().to
              ? <Link class={`amb-chip amb-link ${c().cls}`} to={c().to!} title={c().title}>{c().text}</Link>
              : <span class={`amb-chip ${c().cls}`} title={c().title}>{c().text}</span>}
          </Show>
          <Show when={ambientChip()}>
            {(c) => c().to
              ? <Link class={`amb-chip amb-link ${c().cls}`} to={c().to!} title={c().title}>{c().text}</Link>
              : <span class={`amb-chip ${c().cls}`} title={c().title}>{c().text}</span>}
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
          <For each={epicClusters()}>
            {(cluster) => (
              <div class="epic-cluster">
                <h3 class="epic-head" title="one effort spanning repos, linked by epic tag (advisory — each half still merges on its own main)">
                  ⇌ {cluster.epic}
                </h3>
                <For each={cluster.items}>
                  {(p) => (
                    <div class="epic-subrow">
                      <span class="epic-repo-badge">{p.repo || "loops"}</span>
                      {forestRow(p, false)}
                    </div>
                  )}
                </For>
              </div>
            )}
          </For>
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

// The forest's "get this ready to go" verb: POST /ship contracts already-merged members,
// restacks every survivor onto fresh origin/main (trees included), and reports the push
// order. Prep/push stay per-node so the outgoing commit message remains editable.
function ShipButton(props: { project: string }) {
  const qc = useQueryClient();
  const [armed, setArmed] = createSignal(false);
  const [busy, setBusy] = createSignal(false);
  const [msg, setMsg] = createSignal<{ text: string; bad?: boolean } | null>(null);
  let disarm: ReturnType<typeof setTimeout>;
  // shared cache with Home's chip — the daemon already classified this forest, so the confirm
  // step previews exactly what it'll do (drop merged ghosts, rebase the rest) rather than firing blind.
  const shipAmbient = createQuery(() => ({
    queryKey: ["restack-ambient"], queryFn: () => provider.restackAmbient(), refetchInterval: 15000,
  }));
  const shipForestBranches = createQuery(() => ({
    queryKey: ["forest-branches"], queryFn: () => provider.forestBranches(), refetchInterval: 60000,
  }));
  const preview = () => {
    const a = shipAmbient.data;
    if (!a?.available || !a.report) return null;
    const inProj = new Set((shipForestBranches.data || []).filter((fb) => fb.project === props.project).map((fb) => fb.branch));
    const b = a.report.branches.filter((x) => inProj.has(x.branch));
    const contract = b.filter((x) => x.verdict === "would-contract").length;
    const rebase = b.filter((x) => x.verdict === "would-restack").length;
    const conflict = b.filter((x) => x.verdict === "will-conflict").length;
    return contract || rebase || conflict ? { contract, rebase, conflict } : null;
  };
  const confirmLabel = () => {
    const p = preview();
    if (!p) return "confirm: contract + restack";
    const parts = [p.contract && `drop ${p.contract}`, p.rebase && `rebase ${p.rebase}`].filter(Boolean);
    return `confirm: ${parts.join(" · ") || "restack"}`;
  };
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
    const r = await fetch(withRepo("/ship"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ project: props.project }),
    })
      .then((x) => x.json() as Promise<{
        ok?: boolean; err?: string; alreadyReady?: boolean; moved?: string[];
        contracted?: { branch: string }[]; order?: { branch: string; unpushed: boolean }[];
      }>)
      .catch((e) => ({ ok: false, err: String(e) }));
    setBusy(false);
    if (r.ok) {
      const re = r as { alreadyReady?: boolean; moved?: string[]; contracted?: { branch: string }[]; order?: { branch: string; unpushed: boolean }[] };
      const pushList = (re.order ?? []).filter((o) => o.unpushed).map((o) => leaf(o.branch));
      const did = [
        re.contracted?.length ? `${re.contracted.length} merged dropped` : "",
        re.moved?.length ? `${re.moved.length} rebased` : "",
      ].filter(Boolean).join(" · ");
      setMsg({
        text: (re.alreadyReady ? "✓ already ready" : `✓ ready — ${did}`)
          + (pushList.length ? ` · push: ${pushList.join(" → ")}` : " · nothing to push"),
      });
      qc.invalidateQueries({ queryKey: ["model"] });
      qc.invalidateQueries({ queryKey: ["forest-health"] });
      qc.invalidateQueries({ queryKey: ["projects"] });
    } else {
      setMsg({ text: `✗ ${r.err || "ship failed"}`, bad: true });
    }
  };
  return (
    <>
      <button
        class="fo-stage"
        classList={{ armed: armed() }}
        disabled={busy()}
        title="ready to ship — drop any member that already merged (rewiring its children), restack the whole forest onto fresh origin/main, then list what to push in order. Refuses if a member has an open PR or a dirty worktree; a conflict restores everything."
        onClick={fire}
      >
        {busy() ? "readying…" : armed() ? confirmLabel() : "▸ ready"}
      </button>
      <Show when={armed() && (preview()?.conflict ?? 0) > 0}>
        <span class="fo-stage-msg bad" title="a conflicting rebase restores every branch to where it was — nothing is left half-done">
          ⚠ {preview()!.conflict} may conflict
        </span>
      </Show>
      <Show when={msg()}>
        <span class="fo-stage-msg" classList={{ bad: !!msg()!.bad }}>{msg()!.text}</span>
      </Show>
    </>
  );
}

function ForestOverview() {
  const { location, navigate } = useViewerLocation();
  const project = () => forestKey(location());
  const ovQc = useQueryClient();
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
            <ShipButton project={project()} />
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
              onContract={canMutate ? async (branch) => {
                await fetch(withRepo("/contract"), {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ branch }),
                }).then((r) => r.json());
                ovQc.invalidateQueries({ queryKey: ["model"] });
                ovQc.invalidateQueries({ queryKey: ["forest-health"] });
                ovQc.invalidateQueries({ queryKey: ["projects"] });
              } : undefined}
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
