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

const OVERLAY =
  "fm-overlay fixed inset-0 z-50 flex items-center justify-center overflow-auto bg-[rgba(8,6,3,0.93)] backdrop-blur-[3px]";
const DOCK =
  "fm-dock sticky top-0 col-[3] flex h-screen items-start justify-center overflow-auto border-l border-rule pt-[30px] px-[8px] pb-[14px]";
const PAGE =
  "fm-page flex [align-items:safe_center] justify-center min-h-[calc(100vh-62px)] overflow-auto pt-[30px] px-[22px] pb-[48px]";

const EDGE_STROKE: Record<string, string> = {
  blessed: "stroke-gold-deep",
  stale: "stroke-del",
  unblessed: "stroke-ink-faint",
};

const PILL_TEXT = "font-mono text-[11.5px] font-medium tracking-[0.02em] [text-anchor:middle]";
// the here pill never re-pinned mono the way play did, so the ghost's display face bleeds in
const HERE_TEXT = "font-display text-[13.5px] font-medium tracking-[0.02em] [text-anchor:middle]";


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

  // ── the old <style> cascade, folded into per-property whole strings (state is all in
  // signals, so classList recomputes what descendant selectors used to). The `!` marks
  // survive translation: an entrance animation with a forwards fill on opacity outranks
  // normal declarations, so every post-entrance opacity override must stay important.
  const treeEdgeClass = (kind: string, lit: boolean, frozen: boolean): string => {
    if (frozen) {
      return spot()
        ? "stroke-ink-faint! opacity-[0.35]! stroke-[1.6] [stroke-dasharray:2_7]! animate-fm-fade!"
        : "stroke-ink-faint! opacity-[0.2]! stroke-[1.4] [stroke-dasharray:2_7]! animate-fm-fade!";
    }
    if (spot()) {
      return lit
        ? "opacity-100! stroke-gold-leaf! stroke-[2.3] animate-fm-fade transition-[opacity,stroke] duration-[140ms]"
        : `opacity-[0.05]! ${EDGE_STROKE[kind]} stroke-[1.4] animate-fm-fade transition-opacity duration-[140ms]`;
    }
    return `${EDGE_STROKE[kind]} stroke-[1.4] animate-fm-fade motion-reduce:animate-none motion-reduce:opacity-100`;
  };
  const faninEdgeClass = (lit: boolean): string => {
    if (spot()) {
      return lit
        ? "opacity-100! stroke-gold-leaf! stroke-[2.3] [stroke-dasharray:7_4] animate-fm-fade-half transition-[opacity,stroke] duration-[140ms]"
        : "opacity-[0.05]! stroke-patina stroke-[1.6] [stroke-dasharray:7_4] animate-fm-fade-half transition-opacity duration-[140ms]";
    }
    return "stroke-patina stroke-[1.6] [stroke-dasharray:7_4] animate-fm-fade-half motion-reduce:animate-none motion-reduce:opacity-50";
  };
  const nodeGClass = (id: string, lit: boolean): string => {
    const base = "cursor-pointer opacity-0 animate-fm-fade-node motion-reduce:animate-none motion-reduce:opacity-100";
    if (kiln() && kilnState(id) === "") return `${base} opacity-[0.26]!`;
    if (spot()) return `${base} ${lit ? "opacity-100!" : "opacity-[0.16]!"} transition-opacity duration-[140ms]`;
    if (kilnState(id) === "pending") return `${base} opacity-[0.34]!`;
    return base;
  };
  // active (and the kiln's current front) flipped every un-pinned text fill to ink via
  // `.fm-node.active text` — one element more specific than the two-class child rules
  const inkFlip = (id: string): boolean => id === props.active() || kilnState(id) === "current";
  const rectClass = (n: SpineNode): string => {
    const id = n.id;
    const hovd = hov() === id;
    const ghost = isGhostId(id);
    const h = nhealth(id);
    const ks = kilnState(id);
    const kilnMark = ks === "set" || ks === "current" || ks === "parked";
    const dam = dams().damSet.has(id);
    const conflict = dams().conflictSet.has(id);
    const active = id === props.active();
    const head = heads().has(id);
    const stroke =
      hovd ? "stroke-ink"
      : kilnMark || conflict || dam ? "stroke-del"
      : ghost ? "stroke-ink-faint"
      : lumen(n) === "blessed" ? "stroke-gold-deep"
      : h?.merged ? "stroke-patina"
      : h?.drifted ? "stroke-del"
      : active ? "stroke-gold-leaf"
      : head ? "stroke-ink-dim"
      : "stroke-rule";
    const width =
      hovd ? "stroke-[2]"
      : ks === "parked" || ks === "current" ? "stroke-[2.3]"
      : ks === "set" ? "stroke-[1.6]"
      : dam ? "stroke-[2]"
      : ghost ? "stroke-[1.3]"
      : h?.merged ? "stroke-[2.2]"
      : h?.drifted ? "stroke-[2.4]"
      : active ? "stroke-[2]"
      : head ? "stroke-[1.6]"
      : "stroke-[1.2]";
    const dash =
      ks === "parked" ? "[stroke-dasharray:5_3]"
      : conflict ? "[stroke-dasharray:4_3]"
      : ghost ? "[stroke-dasharray:5_4]"
      : h?.merged ? "[stroke-dasharray:2_3]"
      : h?.drifted ? "[stroke-dasharray:5_3]"
      : "";
    const fill =
      ghost ? "fill-none"
      : ks === "current" || hovd ? "fill-vellum-edge"
      : "fill-vellum-raise";
    const filter =
      hovd ? "drop-shadow-[0_0_10px_var(--color-gold-wash)]"
      : ks === "parked" ? "drop-shadow-[0_0_9px_var(--color-del)]"
      : ks === "current" ? "drop-shadow-[0_0_11px_var(--color-del)]"
      : dam ? "drop-shadow-[0_0_8px_var(--color-del)]"
      : h?.merged ? "drop-shadow-[0_0_6px_var(--color-patina)]"
      : h?.drifted ? "drop-shadow-[0_0_7px_var(--color-del)]"
      : active ? "drop-shadow-[0_0_9px_var(--color-gold-wash)]"
      : head ? "drop-shadow-[0_0_5px_var(--color-gold-wash)]"
      : "";
    return `${fill} ${stroke} ${width} ${dash} ${filter} transition-[stroke,fill] duration-[150ms]`;
  };
  const dotClass = (n: SpineNode): string => {
    if (isGhostId(n.id)) return "hidden";
    const ks = kilnState(n.id);
    if (ks === "parked") return "fill-del stroke-del animate-fm-pulse motion-reduce:animate-none";
    if (ks === "current") return "fill-del stroke-del animate-fm-kiln-breathe motion-reduce:animate-none";
    if (ks === "set") return "fill-del stroke-del opacity-75";
    if (dams().damSet.has(n.id)) return "fill-del stroke-del animate-fm-pulse";
    const l = lumen(n);
    if (l === "blessed") return "fill-gold-leaf stroke-gold-leaf drop-shadow-[0_0_5px_var(--color-gold-wash)]";
    if (l === "stale") return "fill-del stroke-del";
    return "fill-none stroke-ink-faint";
  };
  const nameClass = (n: SpineNode): string =>
    isGhostId(n.id)
      ? "fill-ink-dim font-display text-[13.5px]"
      : `font-mono text-[11.5px] ${inkFlip(n.id) ? "fill-ink" : "fill-ink-dim"}`;
  const stationClass = (s: Station, id: string): string => {
    const fill =
      s === "shared" ? "fill-patina"
      : s === "ready" ? "fill-ember"
      : inkFlip(id) ? "fill-ink"
      : "fill-ink-faint";
    const op = s === "ready" || hov() === id || id === props.active() ? "opacity-100" : "opacity-80";
    return `font-mono text-[8.5px] uppercase tracking-[0.09em] [text-anchor:end] ${fill} ${op}`;
  };
  const prClass = (pr: BranchPR, id: string): string => {
    const fill =
      pr.review === "CHANGES_REQUESTED" ? "fill-del"
      : pr.review === "APPROVED" ? "fill-gold-leaf"
      : pr.draft ? "fill-ink-faint"
      : `${inkFlip(id) ? "fill-ink" : "fill-patina"} hover:fill-gold-leaf`;
    const deco = pr.toMain === false ? "underline decoration-dashed" : "hover:underline";
    return `cursor-pointer font-mono text-[9.5px] tracking-[0.02em] [text-anchor:start] ${fill} ${deco}`;
  };
  const purposeClass = (id: string): string => {
    const lift = hov() === id || id === props.active();
    return `font-mono text-[9px] [text-anchor:middle] ${
      lift ? "fill-ink-dim opacity-100" : kilnState(id) === "current" ? "fill-ink opacity-[0.72]" : "fill-ink-faint opacity-[0.72]"
    }`;
  };
  const integClass = (id: string): string => {
    const s = integ()[ghostProject(id)];
    const fill =
      s?.clean === true ? "fill-[#7c9a6b]"
      : s && s.clean === false && !s.loading ? "fill-ember"
      : hov() === id ? "fill-ink-dim"
      : "fill-ink-faint";
    return `font-mono text-[10px] [text-anchor:end] ${fill}`;
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
      class={props.page ? PAGE : props.docked ? DOCK : OVERLAY}
      onClick={props.docked || props.page ? undefined : () => props.onClose()}
    >
      <Show when={props.docked}>
        <button
          class="fm-dock-close absolute top-[8px] right-[10px] z-[1] cursor-pointer px-[6px] py-[2px] text-[17px] leading-none text-ink-faint hover:text-ink"
          title="close map"
          onClick={() => props.onClose()}
        >
          ×
        </button>
      </Show>
      <svg
        class={`fm-svg block ${
          props.docked
            ? "mx-auto my-0 h-auto max-w-full max-h-[calc(100vh-44px)]"
            : props.page
              ? "mx-auto my-0 h-auto max-w-full max-h-none"
              : "m-auto h-auto max-w-[94vw] max-h-[90vh]"
        }`}
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
              class={`fm-edge ${e.kind} fill-none opacity-0 ${treeEdgeClass(e.kind, litEdge(e.from, e.to), dams().frozen.has(e.to))}`}
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
            <path
              class={`fm-edge fanin fill-none opacity-0 ${faninEdgeClass(litEdge(e.from, e.to))}`}
              classList={{ lit: litEdge(e.from, e.to) }}
              marker-end="url(#fm-arrow)"
              d={edgePath(e)}
            >
              <title>fan-in: merges after {leafOf(e.from)}</title>
            </path>
          )}
        </For>
        <g
          class={`fm-node fm-main ${nodeGClass("main", !!spot() && spot()!.lit.has("main"))}`}
          classList={{ lit: !!spot() && spot()!.lit.has("main"), hov: hov() === "main" }}
          style={{ "animation-delay": "80ms" }}
          transform={`translate(${layout().mainPos.x},${layout().mainPos.y})`}
          onMouseEnter={() => setHov("main")}
          onMouseLeave={() => setHov(null)}
        >
          <circle r="6" class="fill-gold-leaf drop-shadow-[0_0_7px_var(--color-gold-leaf)]" />
          <text x="16" y="4" class="fill-gold-leaf font-display text-[15px]">main</text>
        </g>
        <For each={layout().list}>
          {(n, i) => {
            const p = () => layout().pos[n.id];
            const w = nodeW(n.id);
            return (
              <Show when={p()}>
                <g
                  class={`fm-node ${lumen(n)} ${nodeGClass(n.id, !!spot() && spot()!.lit.has(n.id))}`}
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
                        <text
                          class={`fm-warn drift font-mono text-[9.5px] tracking-[0.03em] [text-anchor:middle] ${inkFlip(n.id) ? "fill-ink" : "fill-del"}`}
                          x={w / 2}
                          y={NODE_H / 2 + 12}
                        >
                          <title>off its parent (not a git ancestor) — its diff is effectively vs main; restack to separate</title>
                          ⤺ off-parent
                        </text>
                      }
                    >
                      <g
                        class="fm-ghost-pill group/pill cursor-pointer"
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
                        <rect
                          class={`fill-vellum-night stroke-[1.2] ${
                            ghostMode(n.id) === "drop"
                              ? "stroke-ember group-hover/pill:fill-ember"
                              : ghostMode(n.id) === "forward"
                                ? "stroke-gold-leaf group-hover/pill:fill-gold-leaf"
                                : "stroke-rule"
                          }`}
                          x={-pillW(ghostLabel(n.id)) / 2}
                          y={-11}
                          rx={9}
                          width={pillW(ghostLabel(n.id))}
                          height={22}
                        />
                        <text
                          class={`${PILL_TEXT} ${
                            ghostMode(n.id) === "drop"
                              ? "fill-ember group-hover/pill:fill-vellum-night"
                              : ghostMode(n.id) === "forward"
                                ? "fill-gold-leaf group-hover/pill:fill-vellum-night"
                                : "fill-ink-dim"
                          }`}
                          x={0}
                          y={4}
                        >{ghostLabel(n.id)}</text>
                      </g>
                    </Show>
                  </Show>
                  <rect class={rectClass(n)} x="0" y={-NODE_H / 2} rx="8" width={w} height={NODE_H} />
                  <circle class={`dot stroke-[1.5] ${dotClass(n)}`} cx="16" cy="0" r="5" />
                  <text class={nameClass(n)} x={isGhostId(n.id) ? 16 : 30} y="4.5">{leafOf(n.id)}</text>
                  {/* mirrors the PR badge's baseline on the free right side; "edit" is the
                      resting state and the absence of a mark says it more quietly. */}
                  <Show when={!isGhostId(n.id) && nstation(n) !== "edit"}>
                    <text
                      class={`fm-station ${stationClass(nstation(n), n.id)}`}
                      classList={{ [nstation(n)]: true }}
                      x={w}
                      y={-NODE_H / 2 - 6}
                    >
                      <title>{STATION_WHY[nstation(n)]}</title>
                      {nstation(n)}
                    </text>
                  </Show>
                  <Show when={!isGhostId(n.id)}>
                    <text
                      class={`cnt font-mono text-[10px] [text-anchor:end] ${inkFlip(n.id) ? "fill-ink" : "fill-ink-faint"}`}
                      x={w - 12}
                      y="4.5"
                    >{n.clean}/{n.total}</text>
                  </Show>
                  <Show when={!isGhostId(n.id) && prOf(n.id)}>
                    {(pr) => (
                      <text
                        class={`fm-pr ${prClass(pr(), n.id)}`}
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
                        <text class={`fm-purpose ${purposeClass(n.id)}`} x={w / 2} y={NODE_H / 2 + 13 + i() * 10}>
                          <title>{n.description}</title>
                          {line}
                        </text>
                      )}
                    </For>
                  </Show>
                  <Show when={isGhostId(n.id) && canMutate}>
                    <text
                      class={`cnt fm-integ ${integClass(n.id)}`}
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
                          {(() => {
                            const st = () =>
                              integ()[proj()]?.armReset
                                ? "armed"
                                : integ()[proj()]?.playground?.dirty
                                  ? "dirty"
                                  : integ()[proj()]?.playground?.fresh
                                    ? "ready"
                                    : "verb";
                            return (
                              <g
                                class="fm-ghost-pill play group/pill cursor-pointer"
                                classList={{
                                  ready: st() === "ready",
                                  dirty: st() === "dirty",
                                  armed: st() === "armed",
                                }}
                                transform={`translate(${-row() / 2 + pw() / 2}, 0)`}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  clickPlayPill(n.id);
                                }}
                              >
                                <title>{playTitle(proj())}</title>
                                <rect
                                  class={`stroke-[1.2] ${
                                    st() === "armed"
                                      ? "fill-ember stroke-ember"
                                      : st() === "dirty"
                                        ? "fill-vellum-night stroke-ember group-hover/pill:fill-none"
                                        : st() === "ready"
                                          ? "fill-vellum-night stroke-rule group-hover/pill:fill-none group-hover/pill:stroke-[#7c9a6b]"
                                          : "fill-vellum-night stroke-[#7c9a6b] group-hover/pill:fill-[#7c9a6b]"
                                  }`}
                                  x={-pw() / 2}
                                  y={-11}
                                  rx={9}
                                  width={pw()}
                                  height={22}
                                />
                                <text
                                  class={`${PILL_TEXT} ${
                                    st() === "armed"
                                      ? "fill-vellum-night"
                                      : st() === "dirty"
                                        ? "fill-ember"
                                        : st() === "ready"
                                          ? "fill-ink-dim group-hover/pill:fill-[#7c9a6b]"
                                          : "fill-[#7c9a6b] group-hover/pill:fill-vellum-night"
                                  }`}
                                  x={0}
                                  y={4}
                                >{label()}</text>
                              </g>
                            );
                          })()}
                          <Show when={hereLabel(proj())}>
                            {(hlabel) => (
                              <g
                                class="fm-ghost-pill here group/pill cursor-pointer"
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
                                <rect
                                  class={`stroke-[1.2] ${
                                    integ()[proj()]?.hereErr
                                      ? "fill-vellum-night stroke-ember group-hover/pill:fill-none"
                                      : integ()[proj()]?.hereDone
                                        ? "fill-vellum-night stroke-rule group-hover/pill:fill-none group-hover/pill:stroke-gold-leaf"
                                        : "fill-vellum-night stroke-gold-leaf group-hover/pill:fill-gold-leaf"
                                  }`}
                                  x={-hw() / 2}
                                  y={-11}
                                  rx={9}
                                  width={hw()}
                                  height={22}
                                />
                                <text
                                  class={`${HERE_TEXT} ${
                                    integ()[proj()]?.hereErr
                                      ? "fill-ember"
                                      : integ()[proj()]?.hereDone
                                        ? "fill-ink-dim group-hover/pill:fill-gold-leaf"
                                        : "fill-gold-leaf group-hover/pill:fill-vellum-night"
                                  }`}
                                  x={0}
                                  y={4}
                                >{hlabel()}</text>
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

