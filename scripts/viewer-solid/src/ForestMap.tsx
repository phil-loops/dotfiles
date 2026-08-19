// ForestMap — the forest as a STORY-ALIGNED TREE, laid out exactly like the merge-story
// text: one branch per row, indentation = one past the DEEPEST upstream (parent chain
// AND carried `requires` bases), vertical order = landing order (merge rank). The parent
// relationship is carried by geometry — a thin file-tree elbow from the guardian's dot
// into the child's left edge. Three kinds of dependence, three strokes: parent elbows
// (rebase base), `requires` fan-in routed through per-dependent rails in the right
// margin (merge-blocking — the branch carries those commits and cannot land first), and
// faint "lands" runs into the ✦ sink (preview assembly — bookkeeping, not merge). The ✦
// culmination is a sink, not a sibling: it seats on main's own column at the bottom with
// main's spine running down into it — fork off main up top, land back on main at the end.
// Deterministic, no force relaxation, never jitters.
//
// Hover a node to SPOTLIGHT its dependency neighborhood: everything upstream and
// downstream stays lit while the rest dims away — one treatment, with the lit
// edges' arrowheads carrying the direction.
//
// Fully self-contained (own class names + <style>): drops into App.tsx with one
// import + the existing <ForestMap …/> mount — zero shared CSS or lines.
import { createEffect, createMemo, createSignal, onCleanup, onMount, For, Show } from "solid-js";
import { computeForestLayout, lumen, NODE_H, leafOf, isGhostId, nodeW } from "./forestLayout";
import * as Graph from "./forestGraph.ts";
import { contractionDone } from "./contractResult.ts";
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
// `requires` (fanin) and ✦-assembly (lands) edges route orthogonally through the
// dependent's rail (laneX, right margin): out of the prerequisite's right edge, along
// the rail, one arrow into the dependent. Same-rail runs overlap pixel-identically, so
// a dense fan-in reads as one bus that darkens toward its arrow, not N crossing curves.
// The spine is main's own column continuing down into the ✦ sink.
const RAIL_R = 7;
const railPath = (e: { x1: number; y1: number; x2: number; y2: number; laneX?: number }): string => {
  const lane = e.laneX ?? e.x1;
  const dir = e.y2 > e.y1 ? 1 : -1;
  if (Math.abs(e.y2 - e.y1) < RAIL_R * 2 + 2) return `M${e.x1},${e.y1} L${e.x2},${e.y2}`;
  return `M${e.x1},${e.y1} H${lane - RAIL_R} Q${lane},${e.y1} ${lane},${e.y1 + dir * RAIL_R} V${e.y2 - dir * RAIL_R} Q${lane},${e.y2} ${lane - RAIL_R},${e.y2} H${e.x2}`;
};
const edgePath = (e: { x1: number; y1: number; x2: number; y2: number; kind: string; laneX?: number }): string =>
  e.kind === "fanin" || e.kind === "lands" || e.kind === "after"
    ? railPath(e)
    : e.kind === "spine"
      ? `M${e.x1},${e.y1} L${e.x2},${e.y2}`
      : Math.abs(e.x2 - e.x1) < 0.5
        ? `M${e.x1},${e.y1} L${e.x1},${e.y2}`
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

// Contraction outcomes live at MODULE scope: per-mount state meant every navigation back to a
// forest re-ran the auto-drop against cached health — re-dropping already-gone branches (200→404
// pairs) and auto-retrying deterministic 409 refusals on each visit, 43% of /contract calls
// failing in the 2026-08 telemetry window. Gone nodes stay gone and a parked refusal blocks the
// auto-fire for the page's lifetime; a manual pill click still retries.
const [contractGone, setContractGone] = createSignal<ReadonlySet<string>>(new Set());
const [contractParked, setContractParked] = createSignal<Record<string, string>>({});
// the two deterministic refusal families get a pill-sized name; the full err stays in the title
const shortContractErr = (err: string): string =>
  /unmerged/i.test(err) ? "unmerged work — no drop"
  : /left standing|rebase|conflict/i.test(err) ? "rewire conflict"
  : "drop failed";

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
  onContract?: (branch: string) => Promise<{ status: number; ok?: boolean; err?: string }>;
}) {
  const nhealth = (id: string) => props.health?.()?.[id];
  // landed = this node's CURRENT work is fully in main: merged PR AND contractable. A merged
  // PR with a live follow-on commit is a normal node again — `merged` alone is the branch's
  // history, not its state, and ghost dress on it reads "done" over work the team hasn't seen.
  const landed = (id: string): boolean => {
    const h = nhealth(id);
    return !!h?.merged && !!h.contractable;
  };
  // the one-dep test: exactly one `requires` on a main-rooted branch is a mis-encoded
  // chain (requires is reserved for converging 2+ bases) — same rule as stack-doctor ⛓
  const misChain = (n: SpineNode) =>
    !isGhostId(n.id) && (!n.parent || n.parent === "main") && (n.requires?.length ?? 0) === 1;
  // shape lints beyond ⛓ — mechanically-detectable dishonesty in the graph, one quiet
  // chip at a time (highest severity wins; same sub-node slot, same yield chain).
  const shapeLint = (n: SpineNode): { mark: string; label: string; title: string } | null => {
    if (isGhostId(n.id)) return null;
    const byId = model().byId;
    const chainOf = (start: string | undefined): Set<string> => {
      const s = new Set<string>();
      let x = start, g = 0;
      while (x && x !== "main" && byId[x] && g++ < 64) { s.add(x); x = byId[x].parent; }
      return s;
    };
    const reqs = n.requires || [];
    const ancReq = reqs.find((r) => chainOf(n.parent).has(r));
    if (ancReq) return { mark: "⌫", label: "requires already ancestral", title: `\`requires ${ancReq}\` is already in the parent chain — pure config debt, drop the entry` };
    for (const a of reqs) {
      const up = chainOf(byId[a]?.parent);
      const b = reqs.find((r) => r !== a && up.has(r));
      if (b) return { mark: "⑂", label: "bases share ancestry", title: `converged bases aren't independent: ${a} builds on ${b} — linearize into one spine` };
    }
    if (n.churn?.length) return { mark: "∿", label: "net-zero churn", title: `commits touch ${n.churn.slice(0, 4).join(", ")}${n.churn.length > 4 ? ` +${n.churn.length - 4}` : ""} but the branch nets zero there — an oops/un-oops pair is hiding in history; it can re-apply as a revert on rebase` };
    return null;
  };
  // The map asks the same question the review surface asks, from the data /forest-health
  // already returns: an existing upstream with nothing ahead of it IS "nothing outgoing".
  // It never learns "ready" (that needs a per-node prep-route — a fresh gh fetch each), so
  // stationOf degrades to edit rather than claiming it: a badge that lies is worse than one
  // that stays quiet. The dot keeps meaning BLESSING; this is its own mark.
  const nstation = (n: SpineNode): Station =>
    stationOf({
      merged: landed(n.id),
      nothingOutgoing: !!nhealth(n.id)?.upstream && !nhealth(n.id)?.ahead,
      blessed: n.clean,
      total: n.total,
    });
  const prOf = (id: string): BranchPR | undefined => props.prs?.()?.[id];
  const [hov, setHov] = createSignal<string | null>(null);
  const [contracting, setContracting] = createSignal<string | null>(null);
  // the merged-ghost next step, keyed off LANDED (merged + contractable), never merged alone
  // — a merged PR with a follow-on commit is a live node, not a ghost, and gets no pill:
  //   drop    — we can mutate → ⊘ drop & rewire (POST /contract)
  //   merged  — read-only → passive ghost, no action
  const ghostMode = (id: string): "drop" | "merged" | null => {
    if (!landed(id)) return null;
    return props.onContract ? "drop" : "merged";
  };
  const ghostLabel = (id: string): string => {
    if (contracting() === id) return "⊘ dropping & rewiring…";
    const err = contractParked()[id];
    if (err) return `⊘ ${shortContractErr(err)} ↻`;
    return ghostMode(id) === "drop" ? "⊘ drop & rewire →" : "✦ merged ghost";
  };
  const pillW = (s: string): number => [...s].length * 6.9 + 18;
  const fireContract = (id: string) => {
    setContracting(id);
    setContractParked(({ [id]: _, ...rest }) => rest);
    Promise.resolve(props.onContract!(id))
      // The branch already being gone IS the outcome contraction was asking for — reporting it as
      // "⊘ drop failed" taught Phil to distrust the auto-drop (2026-07-21). Every other refusal
      // (409 unmerged work, 500) still parks on the pill.
      .then((r) => {
        if (contractionDone(r)) setContractGone((s) => new Set(s).add(id));
        else setContractParked((m) => ({ ...m, [id]: r.err || "contract failed" }));
      })
      // a throw (server bounced mid-request, non-JSON body) used to leave the pill back on its
      // idle label with nothing said — the one failure that looks exactly like never having run
      .catch((e: unknown) => setContractParked((m) => ({ ...m, [id]: (e as Error)?.message || "contract failed" })))
      .finally(() => setContracting(null));
  };

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

  const model = createMemo(() => Graph.indexById(Graph.contractNodes(props.spine(), contractGone())));

  const heads = createMemo(() => Graph.headsOf(model().list));
  const upstreamOf = (id: string): Set<string> => Graph.upstreamOf(model().byId, id);
  const downstreamOf = (id: string): Set<string> => Graph.downstreamOf(model().list, id);

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

  const dams = createMemo(() => Graph.computeDams(model().list, model().byId));

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
  // auto-contract (Phil, 2026-07-20): a merged, fully-contractable node has exactly one correct
  // resolution, so fire the drop on sight instead of waiting for the pill click — narrower than
  // ambient auto-rebase, which stays rejected. One node at a time; a failure parks on the pill
  // (reason named, click to retry) and is never auto-retried — the parked map is module-scoped,
  // so a remount can't re-fire what already refused.
  const autoTried = new Set<string>();
  createEffect(() => {
    if (!props.onContract || contracting()) return;
    const ghost = layout().list.find((n) =>
      !autoTried.has(n.id) && !contractParked()[n.id] && ghostMode(n.id) === "drop");
    if (!ghost) return;
    autoTried.add(ghost.id);
    fireContract(ghost.id);
  });
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
  // fan-in rests at half presence, SOLID and thin — the rails carry the structure now,
  // so texture would only braid where same-rail runs overlap (solid overlaps merge
  // pixel-identically; dashes can't). Patina keeps it distinct from the status-colored
  // parent elbows; hover still lights the full run gold. The ✦-assembly (lands) edges
  // stay the quiet pole: pure bookkeeping, one thin outermost rail.
  // ordering-only fan-in (carries zero of the dep's commits — pure merge-order metadata)
  // stays SOLID like carried fan-in (dashes braid on shared rails) but drops to ink-faint
  // and a hair thinner: the graph stops asserting a code dependency that isn't there.
  const faninEdgeClass = (lit: boolean, ordering?: boolean): string => {
    if (spot()) {
      return lit
        ? "opacity-100! stroke-gold-leaf! stroke-[2.3] animate-fm-fade transition-[opacity,stroke] duration-[140ms]"
        : `opacity-[0.05]! ${ordering ? "stroke-ink-faint stroke-[1.2]" : "stroke-patina stroke-[1.5]"} animate-fm-fade-half transition-opacity duration-[140ms]`;
    }
    return `${ordering ? "stroke-ink-faint stroke-[1.2]" : "stroke-patina stroke-[1.5]"} animate-fm-fade-half motion-reduce:animate-none motion-reduce:opacity-50`;
  };
  const landsEdgeClass = (lit: boolean): string => {
    if (spot()) {
      return lit
        ? "opacity-85! stroke-gold-leaf! stroke-[1.7] animate-fm-fade-half transition-[opacity,stroke] duration-[140ms]"
        : "opacity-[0.04]! stroke-patina stroke-[1] animate-fm-fade-half transition-opacity duration-[140ms]";
    }
    return "stroke-patina stroke-[1] animate-fm-fade-half motion-reduce:animate-none motion-reduce:opacity-50";
  };
  const spineEdgeClass = (lit: boolean): string => {
    if (spot()) {
      return lit
        ? "opacity-90! stroke-gold-leaf! stroke-[1.8] [stroke-dasharray:2_6] animate-fm-fade-half transition-[opacity,stroke] duration-[140ms]"
        : "opacity-[0.05]! stroke-gold-deep stroke-[1.3] [stroke-dasharray:2_6] animate-fm-fade-half transition-opacity duration-[140ms]";
    }
    return "stroke-gold-deep stroke-[1.3] [stroke-dasharray:2_6] animate-fm-fade-half motion-reduce:animate-none motion-reduce:opacity-50";
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
      : landed(id) ? "stroke-patina"
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
      : landed(id) ? "stroke-[2.2]"
      : h?.drifted ? "stroke-[2.4]"
      : active ? "stroke-[2]"
      : head ? "stroke-[1.6]"
      : "stroke-[1.2]";
    const dash =
      ks === "parked" ? "[stroke-dasharray:5_3]"
      : conflict ? "[stroke-dasharray:4_3]"
      : ghost ? "[stroke-dasharray:5_4]"
      : landed(id) ? "[stroke-dasharray:2_3]"
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
      : landed(id) ? "drop-shadow-[0_0_6px_var(--color-patina)]"
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
  const prClass = (pr: BranchPR, id: string, parent?: string): string => {
    const fill =
      pr.review === "CHANGES_REQUESTED" ? "fill-del"
      : pr.review === "APPROVED" ? "fill-gold-leaf"
      : pr.draft ? "fill-ink-faint"
      : `${inkFlip(id) ? "fill-ink" : "fill-patina"} hover:fill-gold-leaf`;
    // base = the node's stack parent is the stacked-PR convention, not an anomaly
    const deco = pr.toMain === false && pr.base !== parent ? "underline decoration-dashed" : "hover:underline";
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
        <For each={layout().edges.filter((e) => e.kind !== "fanin" && e.kind !== "lands" && e.kind !== "spine" && e.kind !== "after")}>
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
        {/* requires edges run the dependent's right-margin rail — merge-blocking
            dependence reads at rest; hover lights the full run gold. */}
        <For each={layout().edges.filter((e) => e.kind === "fanin")}>
          {(e) => (
            <path
              class={`fm-edge fanin fill-none opacity-0 ${faninEdgeClass(litEdge(e.from, e.to), e.meta?.carried === 0)}`}
              classList={{ lit: litEdge(e.from, e.to) }}
              marker-end="url(#fm-arrow)"
              d={edgePath(e)}
            >
              <title>{
                e.meta === undefined
                  ? `fan-in: carries ${leafOf(e.from)} as cherry-picks — cannot land before it`
                  : e.meta.carried === 0
                    ? `merge-order only: carries none of ${leafOf(e.from)}'s ${e.meta.of} commits — no code dependency, ordering is the whole edge`
                    : `fan-in: carries ${e.meta.carried} of ${leafOf(e.from)}'s ${e.meta.of} commits as cherry-picks — cannot land before it`
              }</title>
            </path>
          )}
        </For>
        {/* `after` edges: merge-order only — same rail grammar as fan-in, ordering tone */}
        <For each={layout().edges.filter((e) => e.kind === "after")}>
          {(e) => (
            <path
              class={`fm-edge after fill-none opacity-0 ${faninEdgeClass(litEdge(e.from, e.to), true)}`}
              classList={{ lit: litEdge(e.from, e.to) }}
              marker-end="url(#fm-arrow)"
              d={edgePath(e)}
            >
              <title>merge-order only: lands after {leafOf(e.from)} — content-independent, no rebase coupling</title>
            </path>
          )}
        </For>
        {/* ✦-assembly edges rest barely-there — the preview gathers the tips, but nothing
            here blocks a merge; a heavier stroke would lie about the dependence. */}
        <For each={layout().edges.filter((e) => e.kind === "lands")}>
          {(e) => (
            <path
              class={`fm-edge lands fill-none opacity-0 ${landsEdgeClass(litEdge(e.from, e.to))}`}
              classList={{ lit: litEdge(e.from, e.to) }}
              marker-end="url(#fm-arrow)"
              d={edgePath(e)}
            >
              <title>assembled into the ✦ preview — not a merge dependency</title>
            </path>
          )}
        </For>
        {/* main's spine continues down into the ✦ sink: the forest forks off main at the
            top and lands back on it at the bottom. */}
        <For each={layout().edges.filter((e) => e.kind === "spine")}>
          {(e) => (
            <path
              class={`fm-edge spine fill-none opacity-0 ${spineEdgeClass(litEdge(e.from, e.to))}`}
              classList={{ lit: litEdge(e.from, e.to) }}
              marker-end="url(#fm-arrow)"
              d={edgePath(e)}
            >
              <title>main flows on — the whole project lands back here</title>
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
                    merged: landed(n.id),
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
                  <Show when={!dams().damSet.has(n.id) && (nhealth(n.id)?.drifted || landed(n.id))}>
                    <Show
                      when={landed(n.id)}
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
                        classList={{ drop: ghostMode(n.id) === "drop" }}
                        transform={`translate(${w / 2}, ${NODE_H / 2 + 17})`}
                        onClick={(e) => {
                          e.stopPropagation();
                          if (contracting() === n.id) return;
                          if (ghostMode(n.id) === "drop") {
                            fireContract(n.id);
                          }
                        }}
                      >
                        <title>
                          {contractParked()[n.id]
                            ? `${contractParked()[n.id]} — click to retry`
                            : ghostMode(n.id) === "drop"
                            ? "already merged AND fully contractable — drops this branch, rebases + rewires its children onto its parent (server re-verifies; ▸ ready does the whole forest)"
                            : "merged into main (ghost)"}
                        </title>
                        <rect
                          class={`fill-vellum-night stroke-[1.2] ${
                            ghostMode(n.id) === "drop"
                              ? "stroke-ember group-hover/pill:fill-ember"
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
                        class={`fm-pr ${prClass(pr(), n.id, n.parent)}`}
                        classList={{
                          draft: !!pr().draft,
                          approved: pr().review === "APPROVED",
                          changes: pr().review === "CHANGES_REQUESTED",
                          // a stacked child TARGETING its parent's open PR is the convention
                          // (GitHub retargets to main when the parent merges) — warn only on
                          // a base that is neither main nor this node's stack parent
                          offbase: pr().toMain === false && pr().base !== n.parent,
                        }}
                        x={14}
                        y={-NODE_H / 2 - 6}
                        onClick={(e) => { e.stopPropagation(); window.open(pr().url, "_blank", "noopener"); }}
                      >
                        <title>
                          {pr().toMain === false && pr().base !== n.parent ? `⚠ PR targets ${pr().base} — neither main nor this branch's parent. ` : ""}
                          {pr().toMain === false && pr().base === n.parent ? `stacked on the parent PR (${pr().base}) · ` : ""}
                          {pr().review === "APPROVED" ? "approved · " : pr().review === "CHANGES_REQUESTED" ? "changes requested · " : ""}
                          open #{pr().num} on GitHub
                        </title>
                        {pr().draft ? "◌ draft" : "↗ PR"} #{pr().num}
                      </text>
                    )}
                  </Show>
                  {/* drifted hides the purpose like merged does — the ⤺ off-parent warn draws in
                      the same sub-node slot (NODE_H/2+12 vs +13) and the two overprint; the ⛓
                      and ∅ marks share that slot too, so each state yields to the one above it */}
                  <Show when={misChain(n) && !landed(n.id) && !nhealth(n.id)?.drifted && !dams().damSet.has(n.id)}>
                    <text
                      class={`fm-warn font-mono text-[9.5px] tracking-[0.03em] [text-anchor:middle] ${inkFlip(n.id) ? "fill-ink" : "fill-del"}`}
                      x={w / 2}
                      y={NODE_H / 2 + 12}
                    >
                      <title>one `requires` on a main-rooted branch is a mis-encoded chain — set parent={n.requires![0]} and drop the requires</title>
                      ⛓ mis-encoded chain
                    </text>
                  </Show>
                  <Show when={!misChain(n) && shapeLint(n) && !landed(n.id) && !nhealth(n.id)?.drifted && !dams().damSet.has(n.id)}>
                    <text
                      class={`fm-warn font-mono text-[9.5px] tracking-[0.03em] [text-anchor:middle] ${inkFlip(n.id) ? "fill-ink" : "fill-del"}`}
                      x={w / 2}
                      y={NODE_H / 2 + 12}
                    >
                      <title>{shapeLint(n)!.title}</title>
                      {shapeLint(n)!.mark} {shapeLint(n)!.label}
                    </text>
                  </Show>
                  <Show when={!isGhostId(n.id) && !misChain(n) && n.description && !landed(n.id) && !nhealth(n.id)?.drifted && (dams().damSet.has(n.id) || !shapeLint(n))}>
                    <For each={wrapPurpose(n.description!, w)}>
                      {(line, i) => (
                        <text class={`fm-purpose ${purposeClass(n.id)}`} x={w / 2} y={NODE_H / 2 + 13 + i() * 10}>
                          <title>{n.description}</title>
                          {line}
                        </text>
                      )}
                    </For>
                  </Show>
                  <Show when={!isGhostId(n.id) && !misChain(n) && !n.description && !landed(n.id) && !nhealth(n.id)?.drifted}>
                    <text
                      class={`fm-purpose font-mono text-[9px] [text-anchor:middle] ${inkFlip(n.id) ? "fill-ink" : "fill-ink-faint"}`}
                      x={w / 2}
                      y={NODE_H / 2 + 13}
                    >
                      <title>no branch description — an unfinished operation; git branch --edit-description names the thesis</title>
                      ∅ no purpose
                    </text>
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

