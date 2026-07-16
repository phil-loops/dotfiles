// ForestMap — the forest as a STORY-ALIGNED TREE, laid out exactly like the merge-story
// text: one branch per row, indentation = depth in the parent tree, vertical order =
// landing order (merge rank), ghost culmination last. The parent relationship is carried
// by geometry — a thin file-tree elbow from the guardian's dot into the child's left edge —
// so the resting picture is a TREE with zero edge crossings. `requires` (fan-in) never
// draws a resting edge: it rides as a ⤿ pill beside the node, and its arc materializes
// only under the hover spotlight. Deterministic, no force relaxation, never jitters.
//
// Hover a node to SPOTLIGHT its dependency neighborhood: everything upstream and
// downstream stays lit while the rest dims away — one treatment, with the lit
// edges' arrowheads carrying the direction.
//
// Fully self-contained (own class names + <style>): drops into App.tsx with one
// import + the existing <ForestMap …/> mount — zero shared CSS or lines.
import { createMemo, createSignal, onCleanup, onMount, For, Show } from "solid-js";
import { computeForestLayout, lumen, NODE_H, leafOf, isGhostId, nodeW } from "./forestLayout";
import { stationOf, type Station } from "./nodeStation";

// Why the branch stands there — the map's badge carries the same reason the spine's chip does.
const STATION_WHY: Record<Station, string> = {
  edit: "still shaping — nothing staged for the shared world yet",
  review: "unblessed files left to read",
  ready: "one voiced commit, waiting on the push",
  shared: "every local commit is on origin — the team sees exactly this",
  merged: "its work already landed on main (a ghost — drop & rewire)",
};
import { createQuery } from "@tanstack/solid-query";
import { canMutate, provider } from "./provider";
import type { SpineNode, RestackStatus, BranchPR } from "./types";

// the ghost culmination node is keyed "✦ <project>" (a sentinel, never a real branch).
// the purpose subtitle rides under the pill, wrapped to the pill's width so it never
// sprawls past the node it describes (full text stays in the node's <title>). The pill is
// sized off the BRANCH NAME, so one line guillotined most purposes — wrap to two.
const PURPOSE_LINES = 2;
const wrapPurpose = (s: string, w: number): string[] => {
  const max = Math.max(16, Math.floor((w - 10) / 5.1));
  const lines: string[] = [];
  let rest = s.trim();
  while (rest && lines.length < PURPOSE_LINES) {
    if (rest.length <= max) {
      lines.push(rest);
      rest = "";
      break;
    }
    const cut = rest.lastIndexOf(" ", max);
    lines.push(rest.slice(0, cut > 0 ? cut : max));
    rest = rest.slice(cut > 0 ? cut : max).trim();
  }
  if (rest && lines.length) {
    lines[lines.length - 1] = lines[lines.length - 1].slice(0, max - 1).trimEnd() + "…";
  }
  return lines;
};

// parent edges are file-tree elbow guides: drop from the guardian's dot column, turn
// into the child's left edge. The arrowhead rides the horizontal run, so it always
// enters a node level from the left — indentation and the elbow agree by construction.
// `requires` (fanin) edges rest as a right-lane arc from the prerequisite's right edge
// down to the dependent's right edge (block sorting keeps the prerequisite higher).
const edgePath = (e: { x1: number; y1: number; x2: number; y2: number; kind: string }): string =>
  e.kind === "fanin"
    ? `M${e.x1},${e.y1} C${e.x1 + 58},${e.y1} ${e.x2 + 58},${e.y2} ${e.x2},${e.y2}`
    : `M${e.x1},${e.y1} L${e.x1},${e.y2} L${e.x2},${e.y2}`;


export function ForestMap(props: {
  spine: () => SpineNode[];
  active: () => string;
  health?: () =>
    | Record<string, { drifted: boolean; merged: boolean; contractable: boolean; upstream?: string; ahead?: number }>
    | undefined;
  prs?: () => Record<string, BranchPR> | undefined;
  onPick: (b: string) => void;
  onClose: () => void;
  docked?: boolean;
  // page = the forest's landing hero (full-bleed, no backdrop, no close): the map IS the view
  // at /forests/<project>, not a rail beside a diff. docked = right-rail navigator in detail.
  page?: boolean;
  onHoverNode?: (branch: string) => void;
  onLeaveNode?: () => void;
  // the merged-ghost badge's contextual next step: drop this branch + rewire its children
  // (POST /contract — server re-verifies merged-ness). Absent → badge is read-only.
  onContract?: (branch: string) => Promise<unknown>;
  // the merged-with-follow-on ghost's next step: ready the WHOLE forest (POST /ship —
  // contract merged work first, then restack survivors onto fresh main, in that order).
  // A node-local rebase here would move the node off its parent mid-graph; the forest
  // walk is the only ordering that keeps children seated. Absent → badge is read-only.
  onReady?: () => Promise<unknown>;
}) {
  const nhealth = (id: string) => props.health?.()?.[id];
  // The map asks the same question the review surface asks, from the data /forest-health
  // already returns: an existing upstream with nothing ahead of it IS "nothing outgoing".
  // It never learns "ready" (that needs a per-node prep-route — a fresh gh fetch each), so
  // stationOf degrades to edit rather than claiming it: a badge that lies is worse than one
  // that stays quiet. The dot keeps meaning BLESSING; this is its own mark.
  const nstation = (n: SpineNode): Station =>
    stationOf({
      merged: nhealth(n.id)?.merged,
      nothingOutgoing: !!nhealth(n.id)?.upstream && !nhealth(n.id)?.ahead,
      blessed: n.clean,
      total: n.total,
    });
  const prOf = (id: string): BranchPR | undefined => props.prs?.()?.[id];
  const [hov, setHov] = createSignal<string | null>(null);
  const [contracting, setContracting] = createSignal<string | null>(null);
  const [readying, setReadying] = createSignal(false);
  // the merged-ghost next step, keyed off CONTRACTABLE (rebase-classify exit 20), not merged:
  //   drop    — fully contractable + we can mutate → ⊘ drop & rewire (POST /contract)
  //   forward — merged PR but a newer commit rides on top → not droppable alone; the verb is
  //             the whole-forest ready motion (contract first, THEN restack — never a
  //             node-local rebase, which would unseat the graph mid-chain)
  //   merged  — read-only → passive ghost, no action
  const ghostMode = (id: string): "drop" | "forward" | "merged" | null => {
    const h = nhealth(id);
    if (!h?.merged) return null;
    if (h.contractable) return props.onContract ? "drop" : "merged";
    return props.onReady ? "forward" : "merged";
  };
  const ghostLabel = (id: string): string => {
    if (contracting() === id) return readying() ? "▸ readying forest…" : "⊘ dropping & rewiring…";
    const m = ghostMode(id);
    return m === "drop" ? "⊘ drop & rewire →" : m === "forward" ? "▸ ready forest →" : "✦ merged ghost";
  };
  const pillW = (s: string): number => [...s].length * 6.9 + 18;

  // The ghost ✦ node's one action: integrate-preview. POST /integrate {project} octopus-merges
  // the project's leaves on main in an ephemeral ref (read-only, never pushed) — does the whole
  // thing land clean? Result keyed by project, shown as a badge on the ghost.
  type Playground = { path?: string; exists?: boolean; dirty?: boolean; fresh?: boolean };
  type Integ = {
    loading?: boolean; opening?: boolean; clean?: boolean; detail?: string;
    playground?: Playground; cdCopied?: boolean; armReset?: boolean;
    hereBusy?: boolean; hereDone?: boolean; herePrev?: string; hereErr?: string;
  };
  const [integ, setInteg] = createSignal<Record<string, Integ>>({});
  const ghostProject = (id: string) => id.replace(/^✦\s*/, "");
  const runIntegrate = async (id: string) => {
    if (!canMutate) return; // static snapshot: no live integrate-preview
    const project = ghostProject(id);
    setInteg((s) => ({ ...s, [project]: { loading: true } }));
    try {
      const r = await fetch("/integrate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project }),
      });
      const d = await r.json();
      setInteg((s) => ({ ...s, [project]: { clean: !!d.clean, detail: d.detail || "", playground: d.playground || {} } }));
    } catch {
      setInteg((s) => ({ ...s, [project]: { clean: false, detail: "integrate check failed — is the server up?" } }));
    }
  };
  // clean integration → the ghost grows a pill (the ghost-verb slot): check the whole
  // feature out into the persistent playground worktree (<repo>-integ-<project>, detached
  // HEAD). Refresh only ever moves a playground with NO tracked edits; discarding edits
  // is the armed two-click reset below — never a side effect of anything else.
  const checkoutIntegration = async (id: string, reset = false) => {
    if (!canMutate) return;
    const project = ghostProject(id);
    const cur = integ()[project];
    if (!cur?.clean || cur.loading || cur.opening) return;
    setInteg((s) => ({ ...s, [project]: { ...cur, opening: true, armReset: false } }));
    try {
      const r = await fetch("/integrate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project, ...(reset ? { reset: true } : { checkout: true }) }),
      });
      const d = await r.json();
      const pg: Playground = d.playground || {};
      let cdCopied = false;
      if (d.clean && pg.path && pg.fresh && !pg.dirty) {
        try { await navigator.clipboard.writeText(`cd ${pg.path}`); cdCopied = true; } catch {}
      }
      setInteg((s) => ({ ...s, [project]: { clean: !!d.clean, detail: d.detail || "", playground: pg, cdCopied } }));
    } catch {
      setInteg((s) => ({ ...s, [project]: { ...cur, opening: false } }));
    }
  };
  // a dirty playground never resets on a plain click: first click ARMS the reset
  // (label turns into the question), second click within 5s fires it, anything else disarms.
  const clickPlayPill = (id: string) => {
    const project = ghostProject(id);
    const s = integ()[project];
    if (!s?.clean || s.loading || s.opening) return;
    if (s.playground?.exists && s.playground.dirty) {
      if (!s.armReset) {
        setInteg((m) => ({ ...m, [project]: { ...s, armReset: true } }));
        window.setTimeout(() => {
          setInteg((m) => (m[project]?.armReset ? { ...m, [project]: { ...m[project], armReset: false } } : m));
        }, 5000);
      } else {
        checkoutIntegration(id, true);
      }
      return;
    }
    checkoutIntegration(id);
  };
  // the pill's one label per state — same noun ("playground") through the whole flow.
  const playLabel = (project: string): string | null => {
    const s = integ()[project];
    if (!s?.clean) return null;
    if (s.opening) return "⌗ opening playground…";
    const pg = s.playground;
    if (pg?.exists && pg.dirty) return s.armReset ? "↺ discard edits & reset?" : "⌗ playground has edits — kept";
    if (pg?.exists && pg.fresh) return s.cdCopied ? "⌗ playground ready · cd copied" : "⌗ playground ready";
    if (pg?.exists) return "⌗ update playground →";
    return "⌗ open playground →";
  };
  // the playground's sibling verb: put the same integration in the PRIMARY checkout — the tree
  // the dev server already runs from — instead of a scratch worktree you have to cd into.
  // Detached HEAD on the ephemeral ref; the branch you were on is offered back as the way out.
  const bringHere = async (id: string) => {
    if (!canMutate) return;
    const project = ghostProject(id);
    const cur = integ()[project];
    if (!cur?.clean || cur.loading || cur.opening || cur.hereBusy) return;
    setInteg((s) => ({ ...s, [project]: { ...cur, hereBusy: true, hereErr: "", hereDone: false } }));
    try {
      const r = await fetch("/integrate-here", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ project }),
      });
      const d = await r.json();
      setInteg((s) => ({ ...s, [project]: {
        ...s[project], hereBusy: false, hereDone: !!d.ok,
        herePrev: d.prev || "", hereErr: d.ok ? "" : (d.err || "could not move the checkout"),
      } }));
    } catch {
      setInteg((s) => ({ ...s, [project]: { ...s[project], hereBusy: false, hereErr: "the server did not answer" } }));
    }
  };
  const hereLabel = (project: string): string | null => {
    const s = integ()[project];
    if (!s?.clean) return null;
    if (s.hereBusy) return "⇤ moving your checkout…";
    if (s.hereErr) return "⚠ checkout blocked";
    if (s.hereDone) return "⇤ in your checkout";
    return "⇤ bring to my checkout";
  };
  const hereTitle = (project: string): string => {
    const s = integ()[project];
    if (s?.hereErr) return s.hereErr;
    if (s?.hereDone) {
      const back = s.herePrev ? `git checkout ${s.herePrev}` : "git checkout -";
      return `your main checkout is now on the whole integrated feature (detached — no branch was created or moved). run the dev server against it; \`${back}\` puts it back`;
    }
    return "checks the whole feature out into your MAIN checkout — the tree the dev server runs from — instead of the scratch playground. detached HEAD on the same ephemeral ref: nothing is branched or pushed";
  };
  const playTitle = (project: string): string => {
    const s = integ()[project];
    const pg = s?.playground;
    const path = pg?.path ? `${pg.path}\n` : "";
    if (s?.armReset) return `${path}click again to discard the playground's tracked edits and check out the latest integration — they are not recoverable`;
    if (pg?.exists && pg.dirty) return `${path}the playground has uncommitted edits (yours, or left from an older integration) — nothing touches them. click once to arm ↺ reset, click again to discard & update`;
    if (pg?.exists && pg.fresh) return `${path}up to date with the latest integration — click to copy the cd command again`;
    if (pg?.exists) return `${path}the branches moved since this playground was opened — click to update it (it has no edits to lose)`;
    return "checks the whole feature out into a scratch worktree you can run and edit — refreshed on each open, your edits there are never clobbered; copies the cd command";
  };

  const model = createMemo(() => {
    const list = props.spine();
    const byId: Record<string, SpineNode> = {};
    list.forEach((n) => (byId[n.id] = n));
    return { list, byId };
  });

  // heads: the TIP of each substack — a branch nothing else builds on (nobody's parent,
  // nobody's `requires`). These are the leaves you'd actually check out; everything else
  // is interior plumbing. The ghost endstate is excluded (it's a destination, not a tip).
  const heads = createMemo(() => {
    const { list } = model();
    const hasChild = new Set<string>();
    list.forEach((n) => {
      if (n.parent && n.parent !== "main") hasChild.add(n.parent);
      (n.requires || []).forEach((r) => hasChild.add(r));
    });
    const h = new Set<string>();
    list.forEach((n) => { if (!isGhostId(n.id) && !hasChild.has(n.id)) h.add(n.id); });
    return h;
  });

  // upstream: the parent chain + the transitive `requires` (fan-in) closure —
  // everything that must merge before this branch can. downstream: the transitive
  // dependents (branches whose parent IS this, or that `require` it).
  const upstreamOf = (id: string): Set<string> => {
    const { byId } = model();
    const seen = new Set<string>();
    const visit = (x: string) => {
      const n = byId[x];
      if (!n) return;
      const ups: string[] = [];
      if (n.parent && byId[n.parent]) ups.push(n.parent);
      (n.requires || []).forEach((r) => { if (byId[r]) ups.push(r); });
      ups.forEach((u) => { if (!seen.has(u)) { seen.add(u); visit(u); } });
    };
    visit(id);
    return seen;
  };
  const downstreamOf = (id: string): Set<string> => {
    const { list } = model();
    const seen = new Set<string>();
    const q = [id];
    while (q.length) {
      const x = q.shift()!;
      list.forEach((n) => {
        if (seen.has(n.id)) return;
        if (n.parent === x || (n.requires || []).includes(x)) { seen.add(n.id); q.push(n.id); }
      });
    }
    seen.delete(id);
    return seen;
  };

  // the spotlight set for the hovered node (main → its outbound roots).
  const spot = createMemo(() => {
    const h = hov();
    if (!h) return null;
    if (h === "main") {
      const roots = model().list.filter((n) => n.depth === 0).map((n) => n.id);
      return { h, lit: new Set<string>(["main", ...roots]) };
    }
    return { h, lit: new Set<string>([h, "main", ...upstreamOf(h), ...downstreamOf(h)]) };
  });

  // CHEAP dirty-conflict "dams". A node with uncommitted (tracked) working-tree
  // changes whose paths collide with a DOWNSTREAM node's OWN diff is a dam: once
  // that dirt commits, those descendants conflict on rebase. A dam freezes the
  // flow to its WHOLE downstream subtree — everything below is built on a world
  // about to shift. File-overlap only (no merge attempt): honest "potential",
  // instant, recomputed each render. `frozen` = nodes whose inbound edge is dead.
  const dams = createMemo(() => {
    const { list, byId } = model();
    const damSet = new Set<string>();
    const conflictSet = new Set<string>();
    const frozen = new Set<string>();
    const dirtyOf = (id: string) => byId[id]?.dirty ?? [];
    const ownPaths = (id: string) => (byId[id]?.files ?? []).map((f) => f.path);
    list.forEach((n) => {
      const d = dirtyOf(n.id);
      if (!d.length) return;
      const dset = new Set(d);
      const down = downstreamOf(n.id);
      let active = false;
      down.forEach((c) => {
        if (ownPaths(c).some((p) => dset.has(p))) { conflictSet.add(c); active = true; }
      });
      if (active) {
        damSet.add(n.id);
        down.forEach((c) => frozen.add(c));
      }
    });
    return { damSet, conflictSet, frozen, dirtyOf };
  });

  // KILN: a live restack walking THIS forest, read off /restack-status. The cascade
  // rebases bottom-up, so a heat-front climbs the branches: completed = set (rebased,
  // cooled, awaiting bless), current = rebasing now, pending = not yet reached, parked =
  // stalled on a conflict. Branch ids match the status's branch names directly, so the
  // kiln self-scopes: if the running restack is a DIFFERENT forest, nothing here lights.
  // Polls only while the overlay is mounted (the map is open).
  const kilnQ = createQuery<RestackStatus>(() => ({
    queryKey: ["forestmap-restack"],
    queryFn: () => provider.restackStatus(),
    refetchInterval: 2000,
    enabled: canMutate, // a static snapshot has no live engine to watch
  }));
  const kiln = createMemo(() => {
    const s = kilnQ.data;
    if (!s || (!s.running && !s.paused)) return null;
    const completed = new Set(s.completed ?? []);
    const pending = new Set(s.pending ?? []);
    const current = s.current ?? "";
    const touches = model().list.some(
      (n) => completed.has(n.id) || pending.has(n.id) || n.id === current
    );
    if (!touches) return null;
    return { completed, pending, current, parked: !!s.paused && !s.running };
  });
  const kilnState = (id: string): "" | "set" | "current" | "pending" | "parked" => {
    const k = kiln();
    if (!k) return "";
    if (id === k.current) return k.parked ? "parked" : "current";
    if (k.completed.has(id)) return "set";
    if (k.pending.has(id)) return "pending";
    return "";
  };

  const layout = createMemo(() => computeForestLayout(model()));
  const litEdge = (from: string, to: string) => {
    const s = spot();
    return !!s && s.lit.has(from) && s.lit.has(to);
  };

  // The page map is sized to its own content (W×H), so a SMALL forest rendered at natural
  // size marooned itself in the middle of a big empty column. Scale it UP to use the room —
  // never DOWN, so a tall forest still renders full-size and scrolls as before. Height comes
  // from the viewport, not the host: .fm-page is content-height, so measuring it would feed
  // the zoom back into itself.
  let host: HTMLDivElement | undefined;
  const [box, setBox] = createSignal({ w: 0, h: 0 });
  const measure = () => {
    if (!host) return;
    const cs = getComputedStyle(host);
    const padX = parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight);
    const padY = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    setBox({
      w: host.clientWidth - padX,
      h: window.innerHeight - host.getBoundingClientRect().top - padY,
    });
  };
  onMount(() => {
    measure();
    window.addEventListener("resize", measure);
    onCleanup(() => window.removeEventListener("resize", measure));
  });
  const MAX_ZOOM = 1.7;
  const zoom = createMemo(() => {
    const { w, h } = box();
    if (!props.page || !w || !h) return 1;
    const l = layout();
    return Math.min(MAX_ZOOM, Math.max(1, Math.min(w / l.W, h / l.H)));
  });

  return (
    <div
      ref={host}
      class={props.page ? "fm-page" : props.docked ? "fm-dock" : "fm-overlay"}
      onClick={props.docked || props.page ? undefined : () => props.onClose()}
    >
      <style>{CSS}</style>
      <Show when={props.docked}>
        <button class="fm-dock-close" title="close map" onClick={() => props.onClose()}>
          ×
        </button>
      </Show>
      <svg
        class="fm-svg"
        classList={{ focusing: !!spot(), kiln: !!kiln(), docked: !!props.docked, page: !!props.page }}
        viewBox={`0 0 ${layout().W} ${layout().H}`}
        width={layout().W * zoom()}
        height={layout().H * zoom()}
        preserveAspectRatio="xMidYMid meet"
        onClick={(e) => e.stopPropagation()}
      >
        <defs>
          <marker id="fm-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="5.5" markerHeight="5.5" orient="auto">
            <path d="M0.5,0.5 L7.5,4 L0.5,7.5 Z" fill="context-stroke" />
          </marker>
        </defs>
        <For each={layout().edges.filter((e) => e.kind !== "fanin")}>
          {(e, i) => (
            <path
              class={`fm-edge ${e.kind}`}
              classList={{ lit: litEdge(e.from, e.to), frozen: dams().frozen.has(e.to) }}
              style={{ "animation-delay": `${i() * 40}ms` }}
              marker-end="url(#fm-arrow)"
              d={edgePath(e)}
            />
          )}
        </For>
        {/* requires edges rest faint in the right lane — the geometry says "lands after"
            without words; the hover spotlight brightens the arc. */}
        <For each={layout().edges.filter((e) => e.kind === "fanin")}>
          {(e) => (
            <path class="fm-edge fanin" classList={{ lit: litEdge(e.from, e.to) }} marker-end="url(#fm-arrow)" d={edgePath(e)}>
              <title>fan-in: merges after {leafOf(e.from)}</title>
            </path>
          )}
        </For>
        <g
          class="fm-node fm-main"
          classList={{ lit: !!spot() && spot()!.lit.has("main"), hov: hov() === "main" }}
          style={{ "animation-delay": "80ms" }}
          transform={`translate(${layout().mainPos.x},${layout().mainPos.y})`}
          onMouseEnter={() => setHov("main")}
          onMouseLeave={() => setHov(null)}
        >
          <circle r="6" />
          <text x="16" y="4">main</text>
        </g>
        <For each={layout().list}>
          {(n, i) => {
            const p = () => layout().pos[n.id];
            const w = nodeW(n.id);
            return (
              <Show when={p()}>
                <g
                  class={`fm-node ${lumen(n)}`}
                  classList={{
                    ghost: isGhostId(n.id),
                    head: heads().has(n.id),
                    active: n.id === props.active(),
                    lit: !!spot() && spot()!.lit.has(n.id),
                    hov: hov() === n.id,
                    dam: dams().damSet.has(n.id),
                    conflict: dams().conflictSet.has(n.id),
                    "kiln-set": kilnState(n.id) === "set",
                    "kiln-current": kilnState(n.id) === "current",
                    "kiln-pending": kilnState(n.id) === "pending",
                    "kiln-parked": kilnState(n.id) === "parked",
                    drifted: !!nhealth(n.id)?.drifted,
                    merged: !!nhealth(n.id)?.merged,
                  }}
                  style={{ "animation-delay": `${120 + i() * 45}ms` }}
                  transform={`translate(${p().x},${p().y})`}
                  onClick={() => props.onPick(isGhostId(n.id) ? "~integration" : n.id)}
                  onMouseEnter={() => {
                    setHov(n.id);
                    // hover the ghost → run the integrate-preview badge once (clean/dirty); clicking
                    // it now SELECTS it — its diff is main..refs/stack/<project>-integration.
                    if (isGhostId(n.id) && !integ()[ghostProject(n.id)]) runIntegrate(n.id);
                    else if (!isGhostId(n.id)) props.onHoverNode?.(n.id);
                  }}
                  onMouseLeave={() => {
                    setHov(null);
                    props.onLeaveNode?.();
                  }}
                >
                  <Show when={dams().damSet.has(n.id)}>
                    <title>dirty — downstream conflict on {dams().dirtyOf(n.id).join(", ")}</title>
                  </Show>
                  <Show when={!dams().damSet.has(n.id) && (nhealth(n.id)?.drifted || nhealth(n.id)?.merged)}>
                    <Show
                      when={nhealth(n.id)?.merged}
                      fallback={
                        <text class="fm-warn drift" x={w / 2} y={NODE_H / 2 + 12}>
                          <title>off its parent (not a git ancestor) — its diff is effectively vs main; restack to separate</title>
                          ⤺ off-parent
                        </text>
                      }
                    >
                      <g
                        class="fm-ghost-pill"
                        classList={{ drop: ghostMode(n.id) === "drop", forward: ghostMode(n.id) === "forward" }}
                        transform={`translate(${w / 2}, ${NODE_H / 2 + 17})`}
                        onClick={(e) => {
                          e.stopPropagation();
                          if (contracting() === n.id) return;
                          const m = ghostMode(n.id);
                          if (m === "drop") {
                            setContracting(n.id);
                            Promise.resolve(props.onContract!(n.id)).finally(() => setContracting(null));
                          } else if (m === "forward") {
                            // not droppable alone — run the whole ready motion: contract merged
                            // work into fresh main FIRST, then restack survivors root-down.
                            setContracting(n.id);
                            setReadying(true);
                            Promise.resolve(props.onReady!()).finally(() => {
                              setContracting(null);
                              setReadying(false);
                            });
                          }
                        }}
                      >
                        <title>
                          {ghostMode(n.id) === "drop"
                            ? "already merged AND fully contractable — drops this branch, rewires its children onto its parent (server re-verifies; ▸ ready does the whole forest)"
                            : ghostMode(n.id) === "forward"
                              ? "the PR merged but a newer commit rides on top — not droppable alone. Readies the whole forest: merged work contracts into fresh main first, then everything (the follow-on included) restacks in order. A conflict restores every branch."
                              : "merged into main (ghost)"}
                        </title>
                        <rect x={-pillW(ghostLabel(n.id)) / 2} y={-11} rx={9} width={pillW(ghostLabel(n.id))} height={22} />
                        <text x={0} y={4}>{ghostLabel(n.id)}</text>
                      </g>
                    </Show>
                  </Show>
                  <rect x="0" y={-NODE_H / 2} rx="8" width={w} height={NODE_H} />
                  <circle class="dot" cx="16" cy="0" r="5" />
                  <text x={isGhostId(n.id) ? 16 : 30} y="4.5">{leafOf(n.id)}</text>
                  {/* mirrors the PR badge's baseline on the free right side; "edit" is the
                      resting state and the absence of a mark says it more quietly. */}
                  <Show when={!isGhostId(n.id) && nstation(n) !== "edit"}>
                    <text class="fm-station" classList={{ [nstation(n)]: true }} x={w} y={-NODE_H / 2 - 6}>
                      <title>{STATION_WHY[nstation(n)]}</title>
                      {nstation(n)}
                    </text>
                  </Show>
                  <Show when={!isGhostId(n.id)}>
                    <text class="cnt" x={w - 12} y="4.5">{n.clean}/{n.total}</text>
                  </Show>
                  <Show when={!isGhostId(n.id) && prOf(n.id)}>
                    {(pr) => (
                      <text
                        class="fm-pr"
                        classList={{
                          draft: !!pr().draft,
                          approved: pr().review === "APPROVED",
                          changes: pr().review === "CHANGES_REQUESTED",
                          offbase: pr().toMain === false,
                        }}
                        x={14}
                        y={-NODE_H / 2 - 6}
                        onClick={(e) => { e.stopPropagation(); window.open(pr().url, "_blank", "noopener"); }}
                      >
                        <title>
                          {pr().toMain === false ? `⚠ PR targets ${pr().base} — not main. ` : ""}
                          {pr().review === "APPROVED" ? "approved · " : pr().review === "CHANGES_REQUESTED" ? "changes requested · " : ""}
                          open #{pr().num} on GitHub
                        </title>
                        {pr().draft ? "◌ draft" : "↗ PR"} #{pr().num}
                      </text>
                    )}
                  </Show>
                  <Show when={!isGhostId(n.id) && n.description && !nhealth(n.id)?.merged}>
                    <For each={wrapPurpose(n.description!, w)}>
                      {(line, i) => (
                        <text class="fm-purpose" x={w / 2} y={NODE_H / 2 + 13 + i() * 10}>
                          <title>{n.description}</title>
                          {line}
                        </text>
                      )}
                    </For>
                  </Show>
                  <Show when={isGhostId(n.id) && canMutate}>
                    <text
                      class="cnt fm-integ"
                      x={w - 12}
                      y="4.5"
                      classList={{
                        clean: integ()[ghostProject(n.id)]?.clean === true,
                        conflict:
                          integ()[ghostProject(n.id)]?.clean === false &&
                          !integ()[ghostProject(n.id)]?.loading,
                      }}
                    >
                      {integ()[ghostProject(n.id)]?.loading
                        ? "checking…"
                        : integ()[ghostProject(n.id)]
                          ? integ()[ghostProject(n.id)]!.clean
                            ? "✓ lands clean"
                            : "⚠ conflicts"
                          : "▸ preview"}
                      <Show when={integ()[ghostProject(n.id)]?.detail}>
                        <title>{integ()[ghostProject(n.id)]!.detail}</title>
                      </Show>
                    </text>
                  </Show>
                  <Show when={isGhostId(n.id) && canMutate && playLabel(ghostProject(n.id))}>
                    {(label) => {
                      // the two destinations for a clean integration sit side by side in the
                      // ghost's verb slot: the scratch playground, or your own checkout.
                      const proj = () => ghostProject(n.id);
                      const pw = () => pillW(label());
                      const hw = () => pillW(hereLabel(proj()) || "");
                      const row = () => pw() + 8 + hw();
                      return (
                        <g transform={`translate(${w / 2}, ${NODE_H / 2 + 17})`}>
                          <g
                            class="fm-ghost-pill play"
                            classList={{
                              ready: !!integ()[proj()]?.playground?.fresh && !integ()[proj()]?.playground?.dirty,
                              dirty: !!integ()[proj()]?.playground?.dirty && !integ()[proj()]?.armReset,
                              armed: !!integ()[proj()]?.armReset,
                            }}
                            transform={`translate(${-row() / 2 + pw() / 2}, 0)`}
                            onClick={(e) => {
                              e.stopPropagation();
                              clickPlayPill(n.id);
                            }}
                          >
                            <title>{playTitle(proj())}</title>
                            <rect x={-pw() / 2} y={-11} rx={9} width={pw()} height={22} />
                            <text x={0} y={4}>{label()}</text>
                          </g>
                          <Show when={hereLabel(proj())}>
                            {(hlabel) => (
                              <g
                                class="fm-ghost-pill here"
                                classList={{
                                  done: !!integ()[proj()]?.hereDone,
                                  err: !!integ()[proj()]?.hereErr,
                                }}
                                transform={`translate(${row() / 2 - hw() / 2}, 0)`}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  bringHere(n.id);
                                }}
                              >
                                <title>{hereTitle(proj())}</title>
                                <rect x={-hw() / 2} y={-11} rx={9} width={hw()} height={22} />
                                <text x={0} y={4}>{hlabel()}</text>
                              </g>
                            )}
                          </Show>
                        </g>
                      );
                    }}
                  </Show>
                </g>
              </Show>
            );
          }}
        </For>
      </svg>
    </div>
  );
}

const CSS = `
.fm-overlay { position: fixed; inset: 0; z-index: 50; display: flex; align-items: center;
  justify-content: center; overflow: auto; background: rgba(8, 6, 3, .93); backdrop-filter: blur(3px); }
.fm-svg { display: block; margin: auto; max-width: 94vw; max-height: 90vh; height: auto; }
/* docked: a persistent right-rail navigator (grid column), not a modal — no backdrop,
   stays open on node-click. The svg scales to the panel width instead of the viewport. */
.fm-dock { grid-column: 3; position: sticky; top: 0; height: 100vh; overflow: auto; border-left: 1px solid var(--rule);
  background: var(--vellum); padding: 30px 8px 14px; display: flex; align-items: flex-start; justify-content: center; }
.fm-svg.docked { max-width: 100%; max-height: calc(100vh - 44px); margin: 0 auto; }
/* page: the forest landing hero — the map fills the main column under its header, no
   backdrop and no close (you leave by picking a node or the back-link). */
/* "safe" centre: a forest taller than the viewport falls back to flex-start, so it stays
   scrollable to the top instead of overflowing past it unreachably. */
.fm-page { display: flex; align-items: safe center; justify-content: center;
  min-height: calc(100vh - 62px); padding: 30px 22px 48px; overflow: auto; }
.fm-svg.page { max-width: 100%; max-height: none; height: auto; margin: 0 auto; }
.fm-dock-close { position: absolute; top: 8px; right: 10px; z-index: 1; background: none; border: none;
  color: var(--ink-faint); font-size: 17px; line-height: 1; cursor: pointer; padding: 2px 6px; }
.fm-dock-close:hover { color: var(--ink); }
/* every edge flows gently by default — the forest is "live water": work is
   integration-ready and the world downstream is coherent. A dam (below) stops it. */
.fm-edge { fill: none; stroke: var(--ink-faint); stroke-width: 1.4; opacity: 0;
  animation: fm-fade .8s ease forwards; }
.fm-edge.blessed { stroke: var(--gold-deep); }
.fm-edge.stale { stroke: var(--del); }
/* the requires arc rests faint (dashed = carried, not based-on) and reads full under the spotlight. */
.fm-edge.fanin { stroke: var(--patina); stroke-width: 1.6; stroke-dasharray: 7 4; animation: fm-fade-half .8s ease forwards; }
.fm-node { cursor: pointer; opacity: 0; animation: fm-fade .45s ease forwards; }
.fm-node rect { fill: var(--vellum-raise); stroke: var(--rule); stroke-width: 1.2; transition: stroke .15s, fill .15s; }
.fm-node:hover rect { stroke: var(--ink-faint); fill: var(--vellum-edge); }
/* HEAD: the tip of a substack — a branch nothing builds on. Brighter ring + soft glow so
   each substack's leaf reads at a glance; intentionally low in the cascade so active, dam,
   kiln, and bless states all override it (a tip that is ALSO any of those shows that instead). */
.fm-node.head rect { stroke: var(--ink-dim); stroke-width: 1.6; filter: drop-shadow(0 0 5px var(--gold-wash)); }
.fm-node.head:hover rect { stroke: var(--ink); }
.fm-node.active rect { stroke: var(--gold-leaf); stroke-width: 2; filter: drop-shadow(0 0 9px var(--gold-wash)); }
.fm-node.drifted rect { stroke: var(--del); stroke-width: 2.4; stroke-dasharray: 5 3; filter: drop-shadow(0 0 7px var(--del)); }
.fm-node.merged rect { stroke: var(--patina); stroke-width: 2.2; stroke-dasharray: 2 3; filter: drop-shadow(0 0 6px var(--patina)); }
.fm-warn { font-family: var(--mono); font-size: 9.5px; text-anchor: middle; letter-spacing: .03em; }
.fm-warn.drift { fill: var(--del); }
/* merged-ghost next-step pill: a backed rect so the verb is legible OVER the edges, in ember
   (drop & rewire — the clean ghost) or gold-leaf (ready forest — merged PR + follow-on). */
.fm-ghost-pill { cursor: pointer; }
.fm-ghost-pill rect { fill: var(--vellum-night, #14110a); stroke: var(--rule, #3a332b); stroke-width: 1.2; }
.fm-ghost-pill text { font-family: var(--mono); font-size: 11.5px; text-anchor: middle; letter-spacing: .02em; font-weight: 500; fill: var(--ink-dim, #a89e8c); }
.fm-ghost-pill.drop rect { stroke: var(--ember, #d2732a); }
.fm-ghost-pill.drop text { fill: var(--ember, #d2732a); }
.fm-ghost-pill.drop:hover rect { fill: var(--ember, #d2732a); stroke: var(--ember, #d2732a); }
.fm-ghost-pill.drop:hover text { fill: var(--vellum-night, #14110a); }
.fm-ghost-pill.forward rect { stroke: var(--gold-leaf, #e6b64e); }
.fm-ghost-pill.forward text { fill: var(--gold-leaf, #e6b64e); }
.fm-ghost-pill.forward:hover rect { fill: var(--gold-leaf, #e6b64e); stroke: var(--gold-leaf, #e6b64e); }
.fm-ghost-pill.forward:hover text { fill: var(--vellum-night, #14110a); }
.fm-node text { font-family: var(--mono); font-size: 11.5px; fill: var(--ink-dim); }
.fm-node.active text { fill: var(--ink); }
.fm-node .cnt { fill: var(--ink-faint); font-size: 10px; text-anchor: end; }
/* PR badge — sits above the pill's top-left when the branch has an open PR. Click opens
   GitHub. Neutral patina by default; gold when approved, ember on changes-requested, faint
   when draft, dashed underline when the PR doesn't target main (the stacked-PR anti-pattern). */
/* station: where the branch stands, mirrored opposite the PR badge. Deliberately NOT gold —
   gold is blessing (the dot's language), and a branch can be shared without being blessed. */
.fm-node .fm-station { fill: var(--ink-faint); font-family: var(--mono); font-size: 8.5px;
  text-anchor: end; letter-spacing: .09em; text-transform: uppercase; opacity: .8; }
.fm-node .fm-station.shared { fill: var(--patina); }
.fm-node .fm-station.ready { fill: var(--ember); opacity: 1; }
.fm-node:hover .fm-station, .fm-node.active .fm-station { opacity: 1; }
.fm-node .fm-pr { fill: var(--patina); font-family: var(--mono); font-size: 9.5px; text-anchor: start;
  letter-spacing: .02em; cursor: pointer; }
.fm-node .fm-pr:hover { fill: var(--gold-leaf); text-decoration: underline; }
.fm-node .fm-pr.draft { fill: var(--ink-faint); }
.fm-node .fm-pr.approved { fill: var(--gold-leaf); }
.fm-node .fm-pr.changes { fill: var(--del); }
.fm-node .fm-pr.offbase { text-decoration: underline dashed; }
/* purpose subtitle — the branch's one-line thesis under the pill, dim so the name leads;
   lifts to ink-dim on hover/active so the focused node's intent is fully legible. */
.fm-node .fm-purpose { fill: var(--ink-faint); font-family: var(--mono); font-size: 9px; text-anchor: middle; opacity: .72; }
.fm-node:hover .fm-purpose, .fm-node.active .fm-purpose { fill: var(--ink-dim); opacity: 1; }
/* integrate-preview badge on the ghost node — mono + small (beats the ghost's italic display
   via the extra class), faint until you hover, ember when the project won't land clean. */
.fm-node.ghost .fm-integ { fill: var(--ink-faint); font-style: normal; font-family: var(--mono); font-size: 10px; text-anchor: end; }
.fm-node.ghost:hover .fm-integ { fill: var(--ink-dim); }
.fm-node.ghost .fm-integ.clean { fill: var(--moss, #7c9a6b); }
.fm-node.ghost .fm-integ.conflict { fill: var(--ember, #d36a36); }
.fm-node .dot { stroke-width: 1.5; fill: none; }
.fm-node.blessed .dot { fill: var(--gold-leaf); stroke: var(--gold-leaf); filter: drop-shadow(0 0 5px var(--gold-wash)); }
.fm-node.blessed rect { stroke: var(--gold-deep); }
.fm-node.stale .dot { fill: var(--del); stroke: var(--del); }
.fm-node.unblessed .dot { stroke: var(--ink-faint); }
.fm-main circle { fill: var(--gold-leaf); filter: drop-shadow(0 0 7px var(--gold-leaf)); }
.fm-main text { fill: var(--gold-leaf); font-family: var(--display); font-style: normal; font-size: 15px; }

/* the endstate ghost (✦ <project>): a destination, not a branch — dashed + faint, no
   blessing dot or count, so it reads as the place the work is headed rather than work itself. */
.fm-node.ghost rect { fill: none; stroke: var(--ink-faint); stroke-width: 1.3; stroke-dasharray: 5 4; }
.fm-node.ghost text { fill: var(--ink-dim); font-family: var(--display); font-style: normal; font-size: 13.5px; }
.fm-node.ghost .dot { display: none; }
.fm-node.ghost:hover rect { stroke: var(--patina); fill: none; }
/* playground pill — the ✦ endstate's verb, earned by a clean integrate check (moss, the
   same material as "✓ lands clean"). Scoped under .fm-node.ghost so the ghost's own
   dashed/display treatment (above, same specificity but later otherwise) can't bleed in.
   States: verb (moss) → ready (settles quiet) → dirty (ember fact: edits kept) →
   armed (filled ember question: one more click discards). */
.fm-node.ghost .fm-ghost-pill.play rect { fill: var(--vellum-night, #14110a); stroke: var(--moss, #7c9a6b); stroke-dasharray: none; }
.fm-node.ghost .fm-ghost-pill.play text { font-family: var(--mono); font-size: 11.5px; fill: var(--moss, #7c9a6b); }
.fm-node.ghost .fm-ghost-pill.play:hover rect { fill: var(--moss, #7c9a6b); }
.fm-node.ghost .fm-ghost-pill.play:hover text { fill: var(--vellum-night, #14110a); }
.fm-node.ghost .fm-ghost-pill.play.ready rect { stroke: var(--rule, #3a332b); }
.fm-node.ghost .fm-ghost-pill.play.ready text { fill: var(--ink-dim, #a89e8c); }
.fm-node.ghost .fm-ghost-pill.play.ready:hover rect { fill: none; stroke: var(--moss, #7c9a6b); }
.fm-node.ghost .fm-ghost-pill.play.ready:hover text { fill: var(--moss, #7c9a6b); }
.fm-node.ghost .fm-ghost-pill.play.dirty rect { stroke: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.play.dirty text { fill: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.play.dirty:hover rect { fill: none; stroke: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.play.dirty:hover text { fill: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.play.armed rect { fill: var(--ember, #d2732a); stroke: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.play.armed text { fill: var(--vellum-night, #14110a); }
.fm-node.ghost .fm-ghost-pill.here rect { fill: var(--vellum-night, #14110a); stroke: var(--gold-leaf, #e6b64e); stroke-dasharray: none; }
.fm-node.ghost .fm-ghost-pill.here text { fill: var(--gold-leaf, #e6b64e); }
.fm-node.ghost .fm-ghost-pill.here:hover rect { fill: var(--gold-leaf, #e6b64e); }
.fm-node.ghost .fm-ghost-pill.here:hover text { fill: var(--vellum-night, #14110a); }
.fm-node.ghost .fm-ghost-pill.here.done rect { stroke: var(--rule, #3a332b); }
.fm-node.ghost .fm-ghost-pill.here.done text { fill: var(--ink-dim, #a89e8c); }
.fm-node.ghost .fm-ghost-pill.here.done:hover rect { fill: none; stroke: var(--gold-leaf, #e6b64e); }
.fm-node.ghost .fm-ghost-pill.here.done:hover text { fill: var(--gold-leaf, #e6b64e); }
.fm-node.ghost .fm-ghost-pill.here.err rect { stroke: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.here.err text { fill: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.here.err:hover rect { fill: none; stroke: var(--ember, #d2732a); }
.fm-node.ghost .fm-ghost-pill.here.err:hover text { fill: var(--ember, #d2732a); }

/* DAMS: a dirty branch whose uncommitted paths collide with a downstream node's
   own diff. The dam (red, pulsing) stops the water — every edge below it freezes
   to a dim, static trickle, and the descendants it will actually conflict with
   carry a dashed-red outline. The dam holds until the dirt commits + the forest restacks. */
.fm-edge.frozen { stroke: var(--ink-faint) !important; opacity: .2 !important;
  stroke-dasharray: 2 7 !important; animation: fm-fade .8s ease forwards !important; }   /* no drift = no flow */
.fm-node.dam rect { stroke: var(--del); stroke-width: 2; filter: drop-shadow(0 0 8px var(--del)); }
.fm-node.dam .dot { fill: var(--del); stroke: var(--del); animation: fm-pulse 1.6s ease-in-out infinite; }
.fm-node.conflict rect { stroke: var(--del); stroke-dasharray: 4 3; }

/* spotlight: hovering a node dims the field and lights its dependency neighborhood.
   Lit nodes keep their resting colors — no per-direction recolor (gold/ember already
   mean blessed/kiln elsewhere); the lit edges' arrowheads carry the direction.
   !important beats the entrance animation's forwards-fill on opacity. */
.fm-svg.focusing .fm-node { opacity: .16 !important; transition: opacity .14s; }
.fm-svg.focusing .fm-edge { opacity: .05 !important; transition: opacity .14s; }
.fm-svg.focusing .fm-node.lit, .fm-svg.focusing .fm-main.lit { opacity: 1 !important; }
.fm-svg.focusing .fm-node.hov rect { stroke: var(--ink); stroke-width: 2; filter: drop-shadow(0 0 10px var(--gold-wash)); }
.fm-svg.focusing .fm-edge.lit { opacity: 1 !important; stroke: var(--gold-leaf) !important; stroke-width: 2.3;
  transition: opacity .14s, stroke .14s; }
/* a frozen edge stays frozen even when the spotlight would otherwise light it */
.fm-svg.focusing .fm-edge.frozen { opacity: .35 !important; stroke: var(--ink-faint) !important;
  stroke-width: 1.6; stroke-dasharray: 2 7 !important; animation: fm-fade .8s ease forwards !important; }

/* KILN: a restack walking the forest bottom-up — a heat-front climbing the branches.
   Ember throughout, never gold (gold is earned by blessing): set = rebased this run
   (cooled), current = rebasing now (breathing glow), pending = not yet reached (dim),
   parked = stalled on a conflict (dashed + pulse). While the kiln burns, branches the
   walk hasn't touched recede so the front reads clearly. !important beats the entrance
   animation's forwards-fill on opacity (same trick the spotlight uses). */
.fm-svg.kiln .fm-node:not(.kiln-set):not(.kiln-current):not(.kiln-pending):not(.kiln-parked) { opacity: .26 !important; }
.fm-node.kiln-pending { opacity: .34 !important; }
.fm-node.kiln-set rect { stroke: var(--del); stroke-width: 1.6; }
.fm-node.kiln-set .dot { fill: var(--del); stroke: var(--del); opacity: .75; }
.fm-node.kiln-current rect { stroke: var(--del); stroke-width: 2.3; fill: var(--vellum-edge);
  filter: drop-shadow(0 0 11px var(--del)); }
.fm-node.kiln-current .dot { fill: var(--del); stroke: var(--del); animation: fm-kiln-breathe 1.5s ease-in-out infinite; }
.fm-node.kiln-current text { fill: var(--ink); }
.fm-node.kiln-parked rect { stroke: var(--del); stroke-width: 2.3; stroke-dasharray: 5 3;
  filter: drop-shadow(0 0 9px var(--del)); }
.fm-node.kiln-parked .dot { fill: var(--del); stroke: var(--del); animation: fm-pulse 1.6s ease-in-out infinite; }

@keyframes fm-fade { to { opacity: 1; } }
@keyframes fm-fade-half { to { opacity: .5; } }
@keyframes fm-kiln-breathe { 0%, 100% { opacity: .5; } 50% { opacity: 1; } }
@keyframes fm-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .25; } }
@media (prefers-reduced-motion: reduce) {
  .fm-edge, .fm-node { animation: none; opacity: 1; }
  .fm-edge.fanin { opacity: .5; }
  .fm-node.kiln-current .dot, .fm-node.kiln-parked .dot { animation: none; }
}
`;
