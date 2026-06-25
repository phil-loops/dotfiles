// ForestMap — the forest DAG as an SVG, read as a JOURNEY: `main` is pinned at the
// TOP-LEFT (where you are) and the project's culmination — its "endstate" — is pinned
// BOTTOM-RIGHT (where the work is headed). Every branch sits on the main→endstate
// diagonal by its RANK (longest path from main over parent + fan-in edges), so each
// step down the stack moves both right and down; repulsion + edge cohesion fan the
// siblings off that axis. The endstate is the ghost ✦ node when a project has several
// tips (it fans them all in), else the single deepest tip. Deterministic (seeded by
// rank + index, fixed iteration count, no requestAnimationFrame), so it never jitters.
//
// Hover a node to SPOTLIGHT its dependency neighborhood: everything that flows IN
// (its upstream blockers, gold) and OUT (its downstream dependents, ember) lights
// up, the connecting edges flow toward their targets, and the rest dims away.
//
// Fully self-contained (own class names + <style>): drops into App.tsx with one
// import + the existing <ForestMap …/> mount — zero shared CSS or lines.
import { createMemo, createSignal, For, Show } from "solid-js";
import { createQuery } from "@tanstack/solid-query";
import { canMutate, provider } from "./provider";
import type { SpineNode, RestackStatus } from "./types";

const leafOf = (s: string): string => s.split("/").pop() ?? s;
// the ghost culmination node is keyed "✦ <project>" (a sentinel, never a real branch).
const isGhostId = (id: string): boolean => id.startsWith("✦");
const nodeW = (b: string): number => 50 + leafOf(b).length * 7.2 + 34;
const NODE_H = 28;
function lumen(n: SpineNode): "stale" | "blessed" | "unblessed" {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// edges flow pill-bottom → pill-top as a vertical cubic bézier: control points pushed
// down off the source and up off the target so the line leaves and enters vertically.
// Reads as a routed flow instead of a straight diagonal, so siblings stop crossing in a
// tangle, and the vertical entry tangent lands the arrowhead squarely on the target's top.
const edgePath = (e: { x1: number; y1: number; x2: number; y2: number }): string => {
  const c = Math.max(28, Math.abs(e.y2 - e.y1) * 0.5);
  return `M${e.x1},${e.y1} C${e.x1},${e.y1 + c} ${e.x2},${e.y2 - c} ${e.x2},${e.y2}`;
};

// layout constants. COLW/ROWH = x/y advance per rank step (their ratio sets the
// diagonal's slope — near-equal ⇒ a strong ~45° main→endstate axis); REST = the
// spring's natural edge length (≈ one column) so a child settles a step off its parent;
// SPRING = stiffness; RANKK = pull toward each node's diagonal slot.
const COLW = 186, ROWH = 150, REP = 180, REST = 186, SPRING = 0.5, K = 150, RANKK = 0.3, CUT = 340, ITER = 480, PAD = 72;

export function ForestMap(props: {
  spine: () => SpineNode[];
  active: () => string;
  health?: () => Record<string, { drifted: boolean; merged: boolean }> | undefined;
  onPick: (b: string) => void;
  onClose: () => void;
  docked?: boolean;
}) {
  const nhealth = (id: string) => props.health?.()?.[id];
  const [hov, setHov] = createSignal<string | null>(null);

  // The ghost ✦ node's one action: integrate-preview. POST /integrate {project} octopus-merges
  // the project's leaves on main in an ephemeral ref (read-only, never pushed) — does the whole
  // thing land clean? Result keyed by project, shown as a badge on the ghost.
  type Integ = { loading?: boolean; clean?: boolean; detail?: string };
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
      setInteg((s) => ({ ...s, [project]: { clean: !!d.clean, detail: d.detail || "" } }));
    } catch {
      setInteg((s) => ({ ...s, [project]: { clean: false, detail: "integrate check failed — is the server up?" } }));
    }
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
      const down = new Set(model().list.filter((n) => n.depth === 0).map((n) => n.id));
      return { h, up: new Set<string>(), down, lit: new Set<string>(["main", ...down]) };
    }
    const up = upstreamOf(h), down = downstreamOf(h);
    return { h, up, down, lit: new Set<string>([h, "main", ...up, ...down]) };
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

  const layout = createMemo(() => {
    const { list, byId } = model();
    const ids = list.map((n) => n.id);

    // rank = longest path from main over upstream edges (parent + requires). The ghost
    // culmination (parent=main but requires the deep tips) ranks PAST them instead of
    // collapsing to depth 0, so it lands at the far end of the diagonal. main = 0.
    const rankCache: Record<string, number> = {};
    const rankOf = (id: string): number => {
      if (id === "main") return 0;
      const c = rankCache[id];
      if (c != null) return c;
      rankCache[id] = 1; // cycle guard while recursing
      const n = byId[id];
      let r = 1;
      if (n) {
        const ups: string[] = [];
        if (n.parent && n.parent !== "main" && byId[n.parent]) ups.push(n.parent);
        (n.requires || []).forEach((rq) => { if (byId[rq]) ups.push(rq); });
        ups.forEach((u) => { r = Math.max(r, rankOf(u) + 1); });
      }
      return (rankCache[id] = r);
    };
    ids.forEach(rankOf);

    // the endstate: the single culmination the forest builds toward — the highest-rank
    // node (the ghost ✦ when multi-tip, else the deepest tip). Pinned bottom-right as
    // the mirror of main's pinned top-left.
    let endId: string | null = null;
    ids.forEach((b) => { if (endId === null || rankCache[b] > rankCache[endId]) endId = b; });

    // seed every node on its diagonal slot (rank → both x and y); siblings jittered off
    // it deterministically (no Math.random). main + endstate are fixed anchors.
    const diagOf = (id: string) => ({ x: (rankCache[id] || 0) * COLW, y: (rankCache[id] || 0) * ROWH });
    const P: Record<string, { x: number; y: number }> = {};
    ids.forEach((b, i) => {
      const d = diagOf(b);
      P[b] = { x: d.x, y: d.y + ((i * 37) % 90) - 45 };
    });
    const MAIN = { x: 0, y: 0 };
    if (endId) P[endId] = diagOf(endId); // pin the endstate exactly on the diagonal's far corner
    const wOf = (id: string) => (id === "main" ? 40 : nodeW(id));
    const at = (id: string) => (id === "main" ? MAIN : P[id]);

    const links: [string, string][] = [];
    ids.forEach((b) => {
      const p = byId[b].parent;
      links.push([p && p !== "main" && byId[p] ? p : "main", b]);
      (byId[b].requires || []).forEach((r) => { if (byId[r] && r !== b) links.push([r, b]); });
    });

    let temp = K * 1.6;
    for (let it = 0; it < ITER; it++) {
      // keep the endstate parked just past the bottom-right of everything else, so it
      // reads as the literal destination corner no matter how wide the fan-in spreads
      // (a rank slot alone gets overshot by scattered tips). Recomputed as the field settles.
      if (endId) {
        let mx = -Infinity, my = -Infinity;
        for (const b of ids) {
          if (b === endId) continue;
          if (P[b].x > mx) mx = P[b].x;
          if (P[b].y > my) my = P[b].y;
        }
        if (mx > -Infinity) P[endId] = { x: mx + COLW * 0.8, y: my + ROWH * 0.55 };
      }
      const dsp: Record<string, { x: number; y: number }> = {};
      ids.forEach((b) => (dsp[b] = { x: 0, y: 0 }));
      // separation: pairwise repulsion (hard shove out of overlap).
      for (let i = 0; i < ids.length; i++) {
        for (let j = i + 1; j < ids.length; j++) {
          const A = P[ids[i]], B = P[ids[j]];
          let dx = A.x - B.x, dy = A.y - B.y;
          const d = Math.hypot(dx, dy) || 0.01;
          const minD = (wOf(ids[i]) + wOf(ids[j])) / 2 + 80;
          if (d > CUT && d > minD) continue;
          const f = (REP * REP) / d * (d < minD ? 6 : 1);
          dx /= d; dy /= d;
          dsp[ids[i]].x += dx * f; dsp[ids[i]].y += dy * f;
          dsp[ids[j]].x -= dx * f; dsp[ids[j]].y -= dy * f;
        }
      }
      // keep nodes clear of the pinned main anchor: main repels but never moves, so
      // roots don't collapse on top of it under edge cohesion.
      ids.forEach((b) => {
        const dx = P[b].x - MAIN.x, dy = P[b].y - MAIN.y;
        const d = Math.hypot(dx, dy) || 0.01;
        const minD = (wOf(b) + 40) / 2 + 120;
        if (d < CUT || d < minD) {
          const f = (REP * REP) / d * (d < minD ? 6 : 1);
          dsp[b].x += (dx / d) * f; dsp[b].y += (dy / d) * f;
        }
      });
      // diagonal rank bias: pull each node toward its (rank·COLW, rank·ROWH) slot so the
      // sequence flows top-left → bottom-right (the rest-length springs do the spacing).
      ids.forEach((b) => {
        const d = diagOf(b);
        dsp[b].x += (d.x - P[b].x) * RANKK;
        dsp[b].y += (d.y - P[b].y) * RANKK;
      });
      // cohesion: rest-length springs — zero force at REST, attract beyond, repel within,
      // so connected nodes settle ~one column apart instead of collapsing together. main pinned.
      links.forEach(([u, v]) => {
        const A = at(u), B = at(v);
        const dx = B.x - A.x, dy = B.y - A.y, d = Math.hypot(dx, dy) || 0.01;
        const f = ((d - REST) / d) * SPRING;
        if (u !== "main") { dsp[u].x += dx * f; dsp[u].y += dy * f; }
        if (v !== "main") { dsp[v].x -= dx * f; dsp[v].y -= dy * f; }
      });
      ids.forEach((b) => {
        if (b === endId) return; // pinned bottom-right anchor — never moves
        const m = Math.hypot(dsp[b].x, dsp[b].y) || 0.01, s = Math.min(m, temp) / m;
        P[b].x += dsp[b].x * s; P[b].y += dsp[b].y * s;
        // keep everything down-right of main so main stays the top-left anchor.
        if (P[b].x < 56) P[b].x = 56;
        if (P[b].y < 0) P[b].y = 0;
      });
      temp *= 0.985;
    }

    // pack into the canvas with main at the top-left corner.
    let minX = MAIN.x - 8, maxX = MAIN.x + 46, minY = MAIN.y - 14, maxY = MAIN.y + 14;
    ids.forEach((b) => {
      const hw = nodeW(b) / 2;
      minX = Math.min(minX, P[b].x - hw); maxX = Math.max(maxX, P[b].x + hw);
      minY = Math.min(minY, P[b].y - 16); maxY = Math.max(maxY, P[b].y + 16);
    });
    const ox = PAD - minX, oy = PAD - minY;
    const pos: Record<string, { x: number; y: number }> = {};
    ids.forEach((b) => { pos[b] = { x: P[b].x + ox - nodeW(b) / 2, y: P[b].y + oy }; });
    const mainPos = { x: MAIN.x + ox, y: MAIN.y + oy };
    const W = (maxX - minX) + PAD * 2, H = (maxY - minY) + PAD * 2;

    const cx = (b: string) => pos[b].x + nodeW(b) / 2;
    const cy = (b: string) => pos[b].y;

    type Edge = { x1: number; y1: number; x2: number; y2: number; kind: string; from: string; to: string };
    const edges: Edge[] = [];
    list.forEach((n) => {
      // main→root spokes, but NOT to the ghost endstate — it reaches the map via its
      // fan-in edges, so a straight main→ghost line across the whole canvas is noise.
      if (n.depth === 0 && pos[n.id] && !isGhostId(n.id)) {
        edges.push({ x1: mainPos.x, y1: mainPos.y + 6, x2: cx(n.id), y2: cy(n.id) - NODE_H / 2, kind: lumen(n), from: "main", to: n.id });
      }
      const p = n.parent;
      if (p && p !== "main" && pos[p] && pos[n.id]) {
        edges.push({ x1: cx(p), y1: cy(p) + NODE_H / 2, x2: cx(n.id), y2: cy(n.id) - NODE_H / 2, kind: lumen(n), from: p, to: n.id });
      }
      const ancestors = new Set<string>();
      let x: string | undefined = n.parent, guard = 0;
      while (x && x !== "main" && byId[x] && guard++ < 64) { ancestors.add(x); x = byId[x].parent; }
      (n.requires || []).forEach((rq) => {
        if (pos[rq] && pos[n.id] && !ancestors.has(rq)) {
          edges.push({ x1: cx(rq), y1: cy(rq) + NODE_H / 2, x2: cx(n.id), y2: cy(n.id) - NODE_H / 2, kind: "fanin", from: rq, to: n.id });
        }
      });
    });

    return { list, pos, mainPos, W, H, edges };
  });

  const litEdge = (from: string, to: string) => {
    const s = spot();
    return !!s && s.lit.has(from) && s.lit.has(to);
  };

  return (
    <div
      class={props.docked ? "fm-dock" : "fm-overlay"}
      onClick={props.docked ? undefined : () => props.onClose()}
    >
      <style>{CSS}</style>
      <Show when={props.docked}>
        <button class="fm-dock-close" title="close map (m)" onClick={() => props.onClose()}>
          ×
        </button>
      </Show>
      <svg
        class="fm-svg"
        classList={{ focusing: !!spot(), kiln: !!kiln(), docked: !!props.docked }}
        viewBox={`0 0 ${layout().W} ${layout().H}`}
        width={layout().W}
        height={layout().H}
        preserveAspectRatio="xMidYMid meet"
        onClick={(e) => e.stopPropagation()}
      >
        <defs>
          <marker id="fm-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="5.5" markerHeight="5.5" orient="auto">
            <path d="M0.5,0.5 L7.5,4 L0.5,7.5 Z" fill="context-stroke" />
          </marker>
        </defs>
        <For each={layout().edges}>
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
                    up: !!spot() && spot()!.up.has(n.id),
                    down: !!spot() && spot()!.down.has(n.id),
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
                  }}
                  onMouseLeave={() => setHov(null)}
                >
                  <Show when={dams().damSet.has(n.id)}>
                    <title>dirty — downstream conflict on {dams().dirtyOf(n.id).join(", ")}</title>
                  </Show>
                  <Show when={!dams().damSet.has(n.id) && (nhealth(n.id)?.drifted || nhealth(n.id)?.merged)}>
                    <title>
                      {nhealth(n.id)?.merged
                        ? "merged into main (ghost) — restack to contract it (drop + rewire children)"
                        : "off its parent (not a git ancestor) — its diff is effectively vs main; restack to separate"}
                    </title>
                    <text
                      class="fm-warn"
                      classList={{ drift: !!nhealth(n.id)?.drifted, ghost: !!nhealth(n.id)?.merged }}
                      x={w / 2}
                      y={NODE_H / 2 + 12}
                    >
                      {nhealth(n.id)?.merged ? "✦ ghost · merged" : "⤺ off-parent"}
                    </text>
                  </Show>
                  <rect x="0" y={-NODE_H / 2} rx="8" width={w} height={NODE_H} />
                  <circle class="dot" cx="16" cy="0" r="5" />
                  <text x={isGhostId(n.id) ? 16 : 30} y="4.5">{leafOf(n.id)}</text>
                  <Show when={!isGhostId(n.id)}>
                    <text class="cnt" x={w - 12} y="4.5">{n.clean}/{n.total}</text>
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
.fm-dock-close { position: absolute; top: 8px; right: 10px; z-index: 1; background: none; border: none;
  color: var(--ink-faint); font-size: 17px; line-height: 1; cursor: pointer; padding: 2px 6px; }
.fm-dock-close:hover { color: var(--ink); }
/* every edge flows gently by default — the forest is "live water": work is
   integration-ready and the world downstream is coherent. A dam (below) stops it. */
.fm-edge { fill: none; stroke: var(--ink-faint); stroke-width: 1.6; opacity: 0;
  stroke-dasharray: 5 6; animation: fm-fade .8s ease forwards, fm-drift 3.2s linear infinite; }
.fm-edge.blessed { stroke: var(--gold-deep); }
.fm-edge.stale { stroke: var(--del); }
.fm-edge.fanin { stroke: var(--patina); stroke-width: 1.3; stroke-dasharray: 11 3 2 3; animation-delay: .25s; }
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
.fm-warn.ghost { fill: var(--patina); }
.fm-node text { font-family: var(--mono); font-size: 11.5px; fill: var(--ink-dim); }
.fm-node.active text { fill: var(--ink); }
.fm-node .cnt { fill: var(--ink-faint); font-size: 10px; text-anchor: end; }
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
.fm-main text { fill: var(--gold-leaf); font-family: var(--display); font-style: italic; font-size: 15px; }

/* the endstate ghost (✦ <project>): a destination, not a branch — dashed + faint, no
   blessing dot or count, so it reads as the place the work is headed rather than work itself. */
.fm-node.ghost rect { fill: none; stroke: var(--ink-faint); stroke-width: 1.3; stroke-dasharray: 5 4; }
.fm-node.ghost text { fill: var(--ink-dim); font-family: var(--display); font-style: italic; font-size: 13.5px; }
.fm-node.ghost .dot { display: none; }
.fm-node.ghost:hover rect { stroke: var(--patina); fill: none; }

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
   !important beats the entrance animation's forwards-fill on opacity. */
.fm-svg.focusing .fm-node { opacity: .16 !important; transition: opacity .14s; }
.fm-svg.focusing .fm-edge { opacity: .05 !important; transition: opacity .14s; }
.fm-svg.focusing .fm-node.lit, .fm-svg.focusing .fm-main.lit { opacity: 1 !important; }
.fm-svg.focusing .fm-node.up rect { stroke: var(--gold-leaf); stroke-width: 1.8; filter: drop-shadow(0 0 8px var(--gold-wash)); }     /* flows IN  — blockers */
.fm-svg.focusing .fm-node.down rect { stroke: var(--del); stroke-width: 1.8; filter: drop-shadow(0 0 8px var(--del)); }              /* flows OUT — dependents */
.fm-svg.focusing .fm-node.hov rect { stroke: var(--ink); stroke-width: 2; filter: drop-shadow(0 0 10px var(--gold-wash)); }          /* the hovered node */
.fm-svg.focusing .fm-edge.lit { opacity: 1 !important; stroke: var(--gold-leaf) !important; stroke-width: 2.3;
  stroke-dasharray: 6 7; animation: fm-flow .6s linear infinite; }
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
@keyframes fm-kiln-breathe { 0%, 100% { opacity: .5; } 50% { opacity: 1; } }
@keyframes fm-drift { to { stroke-dashoffset: -22; } }  /* gentle ambient flow toward each edge's target */
@keyframes fm-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .25; } }
@keyframes fm-flow { to { stroke-dashoffset: -26; } }  /* dashes flow toward each edge's target */
@media (prefers-reduced-motion: reduce) {
  .fm-edge, .fm-node { animation: none; opacity: 1; }
  .fm-svg.focusing .fm-edge.lit { animation: none; }
  .fm-node.kiln-current .dot, .fm-node.kiln-parked .dot { animation: none; }
}
`;
