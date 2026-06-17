// ForestMap — the forest DAG as an SVG. `main` is pinned at the TOP-LEFT and the
// stack flows down-right from it: x is banded by depth (a soft rank spring keeps
// clean left→right columns) while y is force-relaxed (nodes repel, edges cohere),
// so the picture is organic without the full-2D boids chaos — and main always
// reads from the same corner. Deterministic (seeded by depth + index, fixed
// iteration count, no requestAnimationFrame), so it never jitters between renders.
//
// Hover a node to SPOTLIGHT its dependency neighborhood: everything that flows IN
// (its upstream blockers, gold) and OUT (its downstream dependents, ember) lights
// up, the connecting edges flow toward their targets, and the rest dims away.
//
// Fully self-contained (own class names + <style>): drops into App.tsx with one
// import + the existing <ForestMap …/> mount — zero shared CSS or lines.
import { createMemo, createSignal, For, Show } from "solid-js";
import type { SpineNode } from "./types";

const leafOf = (s: string): string => s.split("/").pop() ?? s;
const nodeW = (b: string): number => 50 + leafOf(b).length * 7.2 + 34;
const NODE_H = 28;
function lumen(n: SpineNode): "stale" | "blessed" | "unblessed" {
  if (n.stale > 0) return "stale";
  if (n.total > 0 && n.clean === n.total) return "blessed";
  return "unblessed";
}

// layout constants. COLW = x-distance per depth band; REST = the spring's natural
// edge length (≈ one column), so a child settles a column from its parent instead of
// collapsing onto it; SPRING = spring stiffness; RANKK = a light rightward bias so
// depth flows left→right from the pinned main.
const COLW = 186, REP = 180, REST = 186, SPRING = 0.5, K = 150, RANKK = 0.14, CUT = 520, ITER = 460, PAD = 72;

export function ForestMap(props: {
  spine: () => SpineNode[];
  active: () => string;
  onPick: (b: string) => void;
  onClose: () => void;
}) {
  const [hov, setHov] = createSignal<string | null>(null);

  const model = createMemo(() => {
    const list = props.spine();
    const byId: Record<string, SpineNode> = {};
    list.forEach((n) => (byId[n.id] = n));
    return { list, byId };
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

  const layout = createMemo(() => {
    const { list, byId } = model();
    const ids = list.map((n) => n.id);

    // seed: x by depth band, y fanned out (deterministic — no Math.random).
    const P: Record<string, { x: number; y: number }> = {};
    ids.forEach((b, i) => {
      P[b] = { x: (byId[b].depth + 1) * COLW, y: 40 + ((i * 53) % 320) };
    });
    const MAIN = { x: 0, y: 0 };
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
      // light rightward bias: nudge x toward the node's depth column so depth reads
      // left→right (the rest-length springs below do the real spacing).
      ids.forEach((b) => { dsp[b].x += ((byId[b].depth + 1) * COLW - P[b].x) * RANKK; });
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
      if (n.depth === 0 && pos[n.id]) {
        edges.push({ x1: mainPos.x, y1: mainPos.y, x2: cx(n.id), y2: cy(n.id), kind: lumen(n), from: "main", to: n.id });
      }
      const p = n.parent;
      if (p && p !== "main" && pos[p] && pos[n.id]) {
        edges.push({ x1: cx(p), y1: cy(p), x2: cx(n.id), y2: cy(n.id), kind: lumen(n), from: p, to: n.id });
      }
      const ancestors = new Set<string>();
      let x: string | undefined = n.parent, guard = 0;
      while (x && x !== "main" && byId[x] && guard++ < 64) { ancestors.add(x); x = byId[x].parent; }
      (n.requires || []).forEach((rq) => {
        if (pos[rq] && pos[n.id] && !ancestors.has(rq)) {
          edges.push({ x1: cx(rq), y1: cy(rq), x2: cx(n.id), y2: cy(n.id), kind: "fanin", from: rq, to: n.id });
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
    <div class="fm-overlay" onClick={() => props.onClose()}>
      <style>{CSS}</style>
      <svg
        class="fm-svg"
        classList={{ focusing: !!spot() }}
        viewBox={`0 0 ${layout().W} ${layout().H}`}
        width={layout().W}
        height={layout().H}
        preserveAspectRatio="xMidYMid meet"
        onClick={(e) => e.stopPropagation()}
      >
        <For each={layout().edges}>
          {(e, i) => (
            <path
              class={`fm-edge ${e.kind}`}
              classList={{ lit: litEdge(e.from, e.to) }}
              style={{ "animation-delay": `${i() * 40}ms` }}
              d={`M${e.x1},${e.y1} L${e.x2},${e.y2}`}
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
                    active: n.id === props.active(),
                    lit: !!spot() && spot()!.lit.has(n.id),
                    up: !!spot() && spot()!.up.has(n.id),
                    down: !!spot() && spot()!.down.has(n.id),
                    hov: hov() === n.id,
                  }}
                  style={{ "animation-delay": `${120 + i() * 45}ms` }}
                  transform={`translate(${p().x},${p().y})`}
                  onClick={() => props.onPick(n.id)}
                  onMouseEnter={() => setHov(n.id)}
                  onMouseLeave={() => setHov(null)}
                >
                  <rect x="0" y={-NODE_H / 2} rx="8" width={w} height={NODE_H} />
                  <circle class="dot" cx="16" cy="0" r="5" />
                  <text x="30" y="4.5">{leafOf(n.id)}</text>
                  <text class="cnt" x={w - 12} y="4.5">{n.clean}/{n.total}</text>
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
.fm-edge { fill: none; stroke: var(--ink-faint); stroke-width: 1.6; opacity: 0;
  animation: fm-fade .8s ease forwards; }
.fm-edge.blessed { stroke: var(--gold-deep); }
.fm-edge.stale { stroke: var(--del); }
.fm-edge.fanin { stroke: var(--patina); stroke-width: 1.3; stroke-dasharray: 11 3 2 3; animation-delay: .25s; }
.fm-node { cursor: pointer; opacity: 0; animation: fm-fade .45s ease forwards; }
.fm-node rect { fill: var(--vellum-raise); stroke: var(--rule); stroke-width: 1.2; transition: stroke .15s, fill .15s; }
.fm-node:hover rect { stroke: var(--ink-faint); fill: var(--vellum-edge); }
.fm-node.active rect { stroke: var(--gold-leaf); stroke-width: 2; filter: drop-shadow(0 0 9px var(--gold-wash)); }
.fm-node text { font-family: var(--mono); font-size: 11.5px; fill: var(--ink-dim); }
.fm-node.active text { fill: var(--ink); }
.fm-node .cnt { fill: var(--ink-faint); font-size: 10px; text-anchor: end; }
.fm-node .dot { stroke-width: 1.5; fill: none; }
.fm-node.blessed .dot { fill: var(--gold-leaf); stroke: var(--gold-leaf); filter: drop-shadow(0 0 5px var(--gold-wash)); }
.fm-node.blessed rect { stroke: var(--gold-deep); }
.fm-node.stale .dot { fill: var(--del); stroke: var(--del); }
.fm-node.unblessed .dot { stroke: var(--ink-faint); }
.fm-main circle { fill: var(--gold-leaf); filter: drop-shadow(0 0 7px var(--gold-leaf)); }
.fm-main text { fill: var(--gold-leaf); font-family: var(--display); font-style: italic; font-size: 15px; }

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

@keyframes fm-fade { to { opacity: 1; } }
@keyframes fm-flow { to { stroke-dashoffset: -26; } }  /* dashes flow toward each edge's target */
@media (prefers-reduced-motion: reduce) {
  .fm-edge, .fm-node { animation: none; opacity: 1; }
  .fm-svg.focusing .fm-edge.lit { animation: none; }
}
`;
