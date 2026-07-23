import { createEffect, createSignal, Show, Switch, Match, onCleanup, type JSX } from "solid-js";
import { useQueryClient } from "@tanstack/solid-query";
import { RouterProvider, useViewerLocation, forestKey, type ViewerLocation } from "./router";
import { canMutate } from "./provider";
import ChatPanel from "./ChatPanel";
import { chatTarget, closeChat } from "./chatDrawer";
import { reconcile as reconcileChats } from "./chatRunner";
import CommandPalette from "./CommandPalette";
import { track, installFetchTracking, installUiTracking } from "./track";
import { ServerStatus } from "./ServerStatus";
import { Activity } from "./Activity";
import { ServersDrawer } from "./ServersDrawer";
import { NodeDetail } from "./NodeDetail";
import { Home } from "./Home";
import { Wiki } from "./Wiki";
import { ForestOverview } from "./ForestOverview";
import { NavRail } from "./NavRail";
import { trackRecent } from "./recents";


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
      <Match when={location().kind === "wiki"}>
        <Wiki />
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
    trackRecent(l); // here, not in the rail — it's hidden on node review but history still counts
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
    qc.invalidateQueries({ queryKey: ["forest-health"] });
    qc.invalidateQueries({ queryKey: ["branch-prs"] });
  };
  // origin checks failing server-side → the page may be rendering a stale world; say so
  // (nothing shows while healthy — the chip is the failure mode's only footprint).
  const [staleOrigin, setStaleOrigin] = createSignal(false);
  const onStale = (e: MessageEvent) => {
    try {
      setStaleOrigin(!!JSON.parse(e.data).failing);
    } catch {
      setStaleOrigin(false);
    }
  };
  const openStream = () => {
    if (!canMutate || es) return; // static snapshot: no live event stream
    es = new EventSource("/events");
    es.addEventListener("update", refresh);
    es.addEventListener("stale", onStale);
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

  // the rail yields on the per-node review surface — every horizontal pixel goes to the diffs;
  // home and the forest overview keep it.
  const showRail = () => {
    const l = loc();
    return l.kind === "home" || l.kind === "wiki" || isForestOverview(l);
  };
  return (
    <>
      <div class={`app-shell grid min-h-screen ${showRail() ? "grid-cols-[96px_1fr] max-[640px]:grid-cols-[1fr]" : "grid-cols-[1fr]"}`}>
        <Show when={showRail()}>
          <NavRail />
        </Show>
        <div class="app-page min-w-0">{props.children}</div>
      </div>
      <ChatDrawerHost />
      <CommandPalette />
      <ServerStatus />
      <Show when={staleOrigin()}>
        <span
          class="pointer-events-none fixed bottom-8 left-[14px] z-[70] font-mono text-[11px] tracking-[0.02em] text-gold"
          title="the server's `git fetch origin` is failing — merged PRs may still render as live"
        >
          origin checks failing — world may be stale
        </span>
      </Show>
      <Activity />
      <ServersDrawer />
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
