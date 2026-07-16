import { createEffect, Show, Switch, Match, onCleanup, type JSX } from "solid-js";
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
import { ForestOverview } from "./ForestOverview";


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
